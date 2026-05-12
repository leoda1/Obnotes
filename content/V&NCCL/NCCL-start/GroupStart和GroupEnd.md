---

---
> 代码location: https://github.com/NVIDIA/nccl/blob/master/src/group.cc 

## 1. 官方的写法

```c++
NCCLCHECK(ncclGroupStart());
  for (int r=0; r<nRanks; r++) {
    NCCLCHECK(ncclSend(((char*)sendbuff)+r*rankOffset, count, type, r, comm, stream));
    NCCLCHECK(ncclRecv(((char*)recvbuff)+r*rankOffset, count, type, r, comm, stream));
  }
NCCLCHECK(ncclGroupEnd());
```

## 2. start

alltoall的多个send recv放到group api内，执行完`ncclGroupStart()` 的时候不会直接启动任务，只会统计`ncclGroupDepth`，大于0的时候告诉NCCL现在是在收集一大组操作。

```c++
inline ncclResult_t ncclGroupStartInternal() {
  ncclGroupDepth++;
  return ncclSuccess;
}
```

当走到`ncclGroupEnd()` ，才开始。

## 3. GroupEnd

### 3.1 groupLaunch前

```c++
// group.cc
ncclResult_t ncclGroupEndInternal(ncclSimInfo_t* simInfo) {
		// ... simInfo关于模拟nccl的略过
		if (ncclGroupDepth == 0) {
    WARN("ncclGroupEnd: not in a group call.");
    ret = ncclInvalidUsage;
    goto exit;
	  }
	  if ((--ncclGroupDepth) > 0) goto exit;
	  
	  //
	  if (ncclGroupCommHead != nullptr || !ncclIntruQueueEmpty(&ncclAsyncJobs) || ncclGroupCommPreconnectHead != nullptr) {
		  ncclGroupJobMain.groupCommHeadPtr = &ncclGroupCommHead;
		  ncclGroupJobMain.asyncJobsPtr = &ncclAsyncJobs;
			//...
			ncclGroupJobMain.initialized = true;
			ncclGroupJobMainPtr = &ncclGroupJobMain;
			//...
		}
		
		if (ncclGroupBlocking == 0) {
		  // 非阻塞执行 拿不到alltoall结果
		  ...
		} else {
		  // 阻塞执行 结束就拿到alltoall结果
		  int savedDev;
      CUDACHECKGOTO(cudaGetDevice(&savedDev), ret, fail);
      NCCLCHECKGOTO(groupLaunch(&ncclGroupJobMainPtr->base, internalSimInfoPtr), ret, fail);
      CUDACHECKGOTO(cudaSetDevice(savedDev), ret, fail);
      if (simInfo) memcpy((void*)simInfo, (void*)internalSimInfoPtr, realSize);
      groupResetJobState(ncclGroupJobMainPtr);
		}
}
```

- 代码先看`ncclGroupDepth`如果直接是0，说明没有`ncclGroupStart`直接退出。然后`--ncclGroupDepth>0`确保当前的`ncclGroupEnd` 是最外层的。
- 然后把当前需要执行的通信任务、异步任务、错误状态等，打包成一个 job 结构。放到`ncclGroupJobMainPtr`。
- 假设这是阻塞的alltoall，那么现在会把`ncclGroupJobMainPtr->base`(就是`ncclAsyncJob`)传给`groupLaunch`。

这里的上层`ncclSend`和`ncclRecv`怎么把他们的任务和数据关联到`groupStart`和`groupEnd`上的？仔细去看了发和收的cc实现，在[collectives.cc](https://github.com/NVIDIA/nccl/blob/master/src/collectives.cc)里面。把ncclSend的参数（buffer，count，type，目标peer，comm，和用哪个stream）这些包装成了`ncclInfo`结构放到`ncclEnqueueCheck`这个API上(在[enqueue.cc](https://github.com/NVIDIA/nccl/blob/master/src/enqueue.cc)内)。

```c++
// enqueue.cc
ncclResult_t ncclEnqueueCheck(struct ncclInfo* info) {
	ncclGroupStartInternal()      // 保证 group 是开启的
  CommCheck(...)                // 检查 comm 合法性
  ncclCommEnsureReady(...)      // 保证 comm 初始化完
  ArgsCheck(...)                // 参数检查（count、datatype 等）
  taskAppend(comm, info)       // 核心：将任务加入队列（放入 ncclAsyncJobs）
  ncclGroupEndInternal()       // 如果 depth==1，这里触发实际执行
  ncclCommGetAsyncError(...)   // 如果是非阻塞，查一下有没有出错
}
```

这个API内部用了一次组开始和一次结束，保证上层代码的`groupEnd`是最外层的。直接看核心的操作`taskAppend`，同样在当前的cc代码当中。

```c++
// enqueue.cc
static ncclResult_t taskAppend(struct ncclComm* comm, struct ncclInfo* info) {
  struct ncclKernelPlanner *planner = &comm->planner;
  if (info->coll == ncclFuncSend || info->coll == ncclFuncRecv) {
	  int peer = info->root;
    ssize_t nBytes = info->count*ncclTypeSize(info->datatype);
    bool isSendNotRecv = info->coll == ncclFuncSend;

    // Must be in thread local group before tasks can be alloc'd in `comm->memScoped`.
    ncclGroupCommJoin(info->comm);
    struct ncclTaskP2p* p2p = ncclMemoryPoolAlloc<struct ncclTaskP2p>(&comm->memPool_ncclTaskP2p, &comm->memPermanent);
    p2p->func = info->coll;
    p2p->buff = (void*)info->recvbuff;
    p2p->count = info->count;
    p2p->datatype = info->datatype;
    p2p->root = info->root;
    p2p->bytes = nBytes;
    p2p->eActivationMask = __atomic_load_n(&ncclProfilerEventMask, __ATOMIC_RELAXED);
    ncclIntruQueueEnqueue(isSendNotRecv ? &planner->peers[peer].sendQueue : &planner->peers[peer].recvQueue,p2p);
    planner->nTasksP2p += 1;
    
	  if (comm->rank != peer) {
		  ...
		  while (peer != (isSendNotRecv ? comm->p2pSchedule[round].sendRank
                                      : comm->p2pSchedule[round].recvRank)) {
          round += 1;
        }
      uint8_t base = ncclP2pChannelBaseForRound(comm, round);
        for (int c=0; c < comm->p2pnChannelsPerPeer; c++) {
          int channelId = ncclP2pChannelForPart(comm->p2pnChannels, base, c);
          if (isSendNotRecv) {
            if (comm->channels[channelId].peers[peer]->send[1].hasSeen == 0) { // P2P uses only 1 connector
              // the send/recv connector is shared among split shared comms. We need to set hasSeen to
              // 1 in order to avoid duplicate connection setup if user group sendrecv ops with split
              // shared comms together.
              comm->channels[channelId].peers[peer]->send[1].hasSeen = 1;
              comm->connectSend[peer] |= (1UL<<channelId);
              ncclGroupCommPreconnect(comm);
            }
          } else {
            // 和发送的反过来的操作
          }
	} else {
		...
	  // 是 Collective 操作（AllReduce、Broadcast 等）
  }
  
  // 把当前操作的stream记录下来
  if (info->stream != planner->streamRecent || planner->streams == nullptr) {
    planner->streamRecent = info->stream;
    struct ncclCudaStreamList* l = planner->streams;
    while (true) {
      if (l == nullptr) { // Got to the end, this must be a new stream.
        struct ncclCudaGraph graph;
        NCCLCHECK(ncclCudaGetCapturingGraph(&graph, info->stream));
        if (planner->streams != nullptr && !ncclCudaGraphSame(planner->capturingGraph, graph)) {
          WARN("Streams given to a communicator within a NCCL group must either be all uncaptured or all captured by the same graph.");
          return ncclInvalidUsage;
        }
        planner->capturingGraph = graph; // C++ struct assignment
        // Add stream to list
        l = ncclMemoryStackAlloc<struct ncclCudaStreamList>(&comm->memScoped);
        l->stream = info->stream;
        l->next = planner->streams;
        planner->streams = l;
        break;
      }
      if (l->stream == info->stream)
        break; // Already seen stream.
      l = l->next;
    }
  }
}
```

- 定义了planner（`ncclKernelPlanner`格式的struct），当前我是P2P的任务，那我就是走第一个if的true分支（这里通过ncclFuncSend和ncclFuncRecv这俩枚举成员变量看现在是ncclSend还是ncclRecv）。
- 进入这个分支后，重点是`ncclGroupCommJoin(info->comm);`这一行
```c++
inline void ncclGroupCommJoin(struct ncclComm* comm) {
  if (comm->groupNext == reinterpret_cast<struct ncclComm*>(0x1)) {
    // Insert comm into ncclGroupCommHead adjacent to sibling comms. This preserves
    // the users program order yet insures siblings occur consecutively. This
    // is required by doLaunches() in "group.cc".
    struct ncclComm** pp = &ncclGroupCommHead;
    while (*pp != nullptr && comm->intraComm0 != (*pp)->intraComm0)
      pp = &(*pp)->groupNext;

    // didn't find its clique, we need to insert it with ascending order based on commHash
    if (*pp == nullptr) {
      pp = &ncclGroupCommHead;
      while (*pp != nullptr && (*pp)->commHash < comm->commHash) pp = &(*pp)->groupNext;
    }
    comm->groupNext = *pp;
    *pp = comm;
    // Comms gets a new memory stack scope upon joining. Each task batched for
    // this comm is allocated there.
    ncclMemoryStackPush(&comm->memScoped);
    // Initialize planner
    ncclKernelPlanner::Peer* tmp = comm->planner.peers;
    memset(&comm->planner, 0, sizeof(comm->planner));
    comm->planner.peers = tmp;
  }

  ncclGroupBlocking = comm->config.blocking;
}
```
    1. 由while内的条件控制comm与兄弟comm是相邻的，可以保留住用户程序中comm的顺序和连续。这是doLaunch前的必要条件。
    2. 如果没找到 sibling /  clique(兄弟 / 同nvlink互联的gpu)，就按 `commHash` 升序插入，保持链表有序。然后comm给pp链表，pp是ncclGroupCommHead，所以就会找到一组操作内comm的头。
    3. comm随后插入到链表当中。然后给comm创建一个新的memory栈，后续任务来了就放这。peers数组保留后清空planner。
接着定义了`ncclTaskP2p`结构的结构体p2p，把info里面的数据都取出来，这样后面不同的send或者recv任务我就能用p2p结构体内的原子变量来保证数据安全。然后每个p2p差不多等价一个info，`ncclIntruQueueEnqueue`把这个p2p丢进planner内的peers的发送队列。planner内的`nTasksP2p` 来计算整个alltoall我当前这个gpu上有多少次发和收的任务。
- 不同rank间的连接，通过planner内的`sendSeen`布尔值来保证这个peer只连接一次，一个group内不会重复连同一个。`p2pSchedule[round]` 表示每轮用哪条channel做p2p，这个while循环就能在从 `p2pSchedule` 中查到，当前这个 peer 是在哪一轮（round）被我（这个 rank）安排发送。有了round和comm通过`ncclP2pChannelBaseForRound`这个API就能得到这个 round 使用的 base channel。接着for loop给每个channel上准备connector(两张网卡NIC之间得有这个，nccl在这上面完成具体的RDMA读写操作)。并给这个comm放到了`ncclGroupCommPreconnect`的API内，同样会找到一组操作内的预连接的comm的头。
- collective集合通讯的部分略过，接下来就是关于stream上的操作了，会把当前stream和planner里面的最近出现过的stream进行判断，出现新的就加入到planner内的streams链表头（`struct ncclCudaStreamList* streams;`，所有当前任务的用户流汇总列表）。新的这个stream会和CUDA Graph捕获的做检查，出现别的Graph的stream就报错。

现在所有任务都在planner内的peers的发送队列或者接收队列。一组操作内的一群comm的头和一群预连接的comm的头现在是ncclGroupCommHead和ncclGroupCommPreconnectHead。现在`groupLaunch(&ncclGroupJobMainPtr->base, internalSimInfoPtr)` 启动的时候没有看到planner，是从外层管理的send和recv的具体任务队列，这里传进去的只有当前comm（看上去是ncclGroupJobMainPtr->base），ncclGroupJobMainPtr是一个指针，共享使用当前线程的 group 任务上下文结构。这玩意进入groupLaunch后又被强制转换回`struct`` ``ncclGroupJob` 

### 3.2 groupLaunch

```c++
static ncclResult_t groupLaunch(struct ncclAsyncJob *job_, ncclSimInfo_t* simInfo = NULL) {
  ncclResult_t ret = ncclSuccess;
  struct ncclGroupJob *gjob = (struct ncclGroupJob*) job_;
  struct ncclComm *groupCommHeadMain = *gjob->groupCommHeadPtr;
  struct ncclComm *groupCommPreconnectHeadMain = *gjob->groupCommPreconnectHeadPtr;
  struct ncclIntruQueue<struct ncclAsyncJob, &ncclAsyncJob::next> *asyncJobsMain = gjob->asyncJobsPtr;

  bool *groupAbortFlag = gjob->abortFlagPtr;

  if (!simInfo && groupCommPreconnectHeadMain != nullptr) {
    struct ncclComm* comm = groupCommPreconnectHeadMain;
    do {
      struct ncclPreconnectJob* job;
      NCCLCHECKGOTO(ncclCalloc(&job, 1), ret, fail);
      job->base.func = ncclP2PPreconnectFunc;
      job->base.undo = nullptr;
      job->base.destructor = free;
      job->base.state = ncclGroupJobRunning;
      job->base.abortFlag = comm->abortFlag;
      job->base.abortFlagDev = comm->abortFlagDev;
      job->comm = comm;
      ncclIntruQueueEnqueue(asyncJobsMain,  (struct ncclAsyncJob*)job); // 加入async queue

      struct ncclComm* next = comm->preconnectNext;
      comm->preconnectNext = reinterpret_cast<struct ncclComm*>(0x1);
      comm = next;
    } while (comm != nullptr); // 遍历comm，加入preconnect queue
  }

  NCCLCHECKGOTO(asyncJobLaunch(asyncJobsMain, groupAbortFlag), ret, fail);

  /* Connect channels at runtime if cumem is supported */
  if (groupCommHeadMain != nullptr) {
    struct ncclComm* cliqueHead = groupCommHeadMain;
    struct ncclComm* comm = NULL;
    struct ncclIntruQueue<struct ncclAsyncJob, &ncclAsyncJob::next> asyncCollJobs;
    ncclIntruQueueConstruct(&asyncCollJobs);
    do {
      // We need to preconnect connections for collectives clique by clique to avoid
      // race condition for split shared comms which can connect the same connections
      // at the same time.
      comm = cliqueHead;
      do {
        bool needConnect = false;
        bool algoNeedConnect[NCCL_NUM_ALGORITHMS];
        memset(algoNeedConnect, 0, sizeof(bool) * NCCL_NUM_ALGORITHMS);

        CUDACHECKGOTO(cudaSetDevice(comm->cudaDev), ret, fail);
        NCCLCHECKGOTO(ncclPrepareTasks(comm, algoNeedConnect, &needConnect, simInfo), ret, fail);

        if (comm->cuMemSupport && needConnect) {
          struct ncclPreconnectJob* job;
          NCCLCHECKGOTO(ncclCalloc(&job, 1), ret, fail);
          job->base.func = ncclCollPreconnectFunc;
          job->base.undo = nullptr;
          job->base.destructor = free;
          job->base.state = ncclGroupJobRunning;
          job->base.abortFlag = comm->abortFlag;
          job->base.abortFlagDev = comm->abortFlagDev;
          job->comm = comm;
          NCCLCHECKGOTO(ncclCalloc(&job->algoNeedConnect, NCCL_NUM_ALGORITHMS), ret, fail);
          memcpy(job->algoNeedConnect, algoNeedConnect, sizeof(bool) * NCCL_NUM_ALGORITHMS);
          ncclIntruQueueEnqueue(&asyncCollJobs, &job->base);
        }
        comm = comm->groupNext;
      } while (comm != nullptr && comm->intraComm0 == cliqueHead->intraComm0);
      // connect
      NCCLCHECKGOTO(asyncJobLaunch(&asyncCollJobs, groupAbortFlag), ret, fail);
      while (!ncclIntruQueueEmpty(&asyncCollJobs)) {
        struct ncclAsyncJob* job = ncclIntruQueueDequeue(&asyncCollJobs);
        if (job->destructor) job->destructor((void*)job);
      }
      cliqueHead = comm;
    } while (cliqueHead != nullptr);

    // done with all buffer allocation, start registration and enqueue
    comm = groupCommHeadMain;
    do {
      CUDACHECKGOTO(cudaSetDevice(comm->cudaDev), ret, fail);
      NCCLCHECKGOTO(ncclTasksRegAndEnqueue(comm), ret, fail); // **************关键点，注册并enqueue
      comm = comm->groupNext;
    } while (comm);
  }

  if ((!simInfo) && (groupCommHeadMain != nullptr)) {
    NCCLCHECKGOTO(doLaunches(groupCommHeadMain), ret, fail);
  }

  while (!ncclIntruQueueEmpty(asyncJobsMain)) {
    struct ncclAsyncJob* job = ncclIntruQueueDequeue(asyncJobsMain);
    if (!job->destroyFlag && job->comm && !job->comm->config.blocking)
      (void) ncclCommSetAsyncError(job->comm, ret);
    if (job->destructor) job->destructor((void*)job);
  }

  while (groupCommHeadMain != nullptr) {
    struct ncclComm* comm = groupCommHeadMain;
    struct ncclComm* next = comm->groupNext;
    // Poll for callbacks sent to us from other threads. Typically these free
    // resources from to our memory pools and UB
    NCCLCHECKGOTO(ncclCommPollCallbacks(comm, /*waitSome=*/false), ret, fail);
    (void) ncclGroupCommLeave(comm);
    if (!comm->config.blocking) {
      (void) ncclCommSetAsyncError(comm, ret);
    }
    groupCommHeadMain = next;
  }

exit:
  return ret;
fail:
  groupCleanup(gjob->groupCommHeadPtr, gjob->groupCommPreconnectHeadPtr, gjob->asyncJobsPtr, gjob->groupErrorPtr, gjob->groupBlockingPtr, gjob->abortFlagPtr, ret);
  goto exit;
}
```

- 传进来的`struct ncclGroupJob *gjob = (struct ncclGroupJob*) job_`现在强制转成了`ncclGroupJob`格式的gjob，gjob在这个函数里接下来只和出现错误的时候清理资源有关了。所以groupLaunch内是有整个group级别的信息的。（ps：具体收发任务则是从job里面找到当前这个comm再去操作。
- 接着，定义预连接job，并给job的函数指针绑定上ncclP2PPreconnectFunc（job结构体里面有comm，comm里面有nranks，知道自己是哪个gpu也知道一共多少gpu后就可以fully connect了，ps：intra-node），job的状态绑定了ncclGroupJobRunning，job的通讯器绑定了当前的comm。。。。。此时把job强制转换为了`ncclAsyncJob*` 格式入队到`asyncJobsMain`这个侵入式队列（`ncclIntruQueue`）中。
- `NCCLCHECKGOTO(asyncJobLaunch(asyncJobsMain, groupAbortFlag), ret, fail);` preconnect job 在这里被真正 launch。job 类型由 `.func = ncclP2PPreconnectFunc`决定，这里还会包括ring，tree，collnet，nvls等选择。
- 再往下出现了clique（比如我定义了comm0，又基于它定义了comm0_1和comm0_2，此时每个comm都预连接会出现rank0和rank1相同channel建立两次）用于给子comm排序执行以避免反复建立连接。
- 然后comm，algoNeedConnect，needConnect和simInfo丢进`ncclPrepareTasks`API（每个 ncclGroup 调用一次来组织用户在 comm->planner 中提交的任务，以便将它们剥离到计划表中）。[这一步我是alltoall是p2p任务，`ncclPrepareTasks`API对于我来说是空转]。之后comm丢进`ncclTasksRegAndEnqueue`。里面一看也没有对planner->peers[*].sendQueue和planner->peers[*].recvQueue中的所有实际任务取出，所以p2p的任务直接来到了doLaunches函数内。

### 3.3 doLaunches

真正launch前的准备，`ncclLaunchPrepare`（enqueue.cc内）。

```c++
// enqueue.cc
ncclResult_t ncclLaunchPrepare(struct ncclComm* comm) {
	ncclResult_t result = ncclSuccess;
  struct ncclKernelPlanner* planner = &comm->planner;
  bool persistent = ncclCudaGraphValid(planner->capturingGraph);
  planner->persistent = persistent;
  int nPlans = 0;
  if (planner->nTasksColl + planner->nTasksP2p != 0) {
    do {
      memset(&planner->wipPlan, 0, sizeof(planner->wipPlan));

      struct ncclKernelPlan* plan = ncclMemoryPoolAlloc<struct ncclKernelPlan>(&comm->memPool_ncclKernelPlan, &comm->memPermanent);
      plan->comm = comm;
      plan->reclaimer.fn = reclaimPlan;
      plan->persistent = persistent;
      // finishPlan() promotes ncclDevWorkStorageType[Fifo|Persistent]->Args if the work can fit.
      plan->workStorageType = persistent ? ncclDevWorkStorageTypePersistent
                                         : ncclDevWorkStorageTypeFifo;

      struct ncclKernelPlanBudget budget;
      budget.inArgsBytes = comm->workArgsBytes - sizeof(struct ncclDevKernelArgs);
      // Non-persistent kernels fill up at most half of our fifo per kernel.
      budget.outArgsBytes = plan->persistent ? (1<<30) : comm->workFifoBytes/2;

      // Drain coll tasks first. This is essential since we partition tasks based
      // on the work budget and p2p work isn't collective. If we were to drain p2p
      // first, the place where we cut the kernel could vary by rank which would
      // cause the "shortest channel first" channel picker to have divergent results.
      if (planner->nTasksColl != 0) {
        NCCLCHECKGOTO(scheduleCollTasksToPlan(comm, plan, &budget), result, failure);
      }
      // And only drain p2p tasks once colls are depleted.
      if (planner->nTasksColl == 0 && planner->nTasksP2p != 0) {
        NCCLCHECKGOTO(scheduleP2pTasksToPlan(comm, plan, &budget), result, failure);
  //..... 部分代码
}
```

`planner` 内已经收集了所有任务，plan负责打包任务变成kernel launch，是从 NCCL 内部 memory pool 中 分配出一个新的 plan，用于装填要launch的工作的内容（workFifo）。这里还会计算一个budget与comm 和 plan一起放到`scheduleP2pTasksToPlan`内。这里就是从 planner.peers[rank].sendQueue / recvQueue把任务搬运到 `plan.p2pTaskQueue`并同步把参数填入 `plan->workFifo`，供 GPU kernel 执行。

```c++
// enqueue.cc
static ncclResult_t scheduleP2pTasksToPlan(
    struct ncclComm* comm, struct ncclKernelPlan* plan, struct ncclKernelPlanBudget* budget
  ) {
	struct ncclKernelPlanner::Peer* peers = comm->planner.peers;
	
	plan->threadPerBlock = std::max(plan->threadPerBlock, NCCL_MAX_NTHREADS);
	if (!plan->kernelSpecialized) {
	    plan->kernelFn = ncclDevKernelForFunc[ncclDevFuncId_P2p()];
	    plan->kernelSpecialized = ncclDevKernelForFuncIsSpecialized[ncclDevFuncId_P2p()];
	}
	
	while (nChannelsMin*nRanks > comm->p2pnChannels && nChannelsMin > 1) nChannelsMin /= 2;
	
	while (comm->planner.nTasksP2p != 0) {
	// ...... 一大坨代码
	}

}
```

- peers内有前面说到的sendQue和recvQue。接着给plan初始化了kernel内核是P2P类型的内核。nChannelsMin和nChannelsMax记录通道合适范围，避免超过硬件承受力。
- 核心的搬运p2p任务是while一直检测`comm->planner.nTasksP2p != 0`，有任务就遍历通信表`p2pSchedule`。这里的头任务send和recv是通过`ncclIntruQueueHead(&peers[comm->p2pSchedule[round].sendRank].sendQueue)` 找到，sendRank是查`p2pSchedule`表得到。自己发送给自己的时候直接free，跳过，任务计数减2。
- 自己发送给别人的时候会用`testBudget` api检查当前plan能塞入的任务，超过budget就会重开一个plan。`struct ncclTaskP2p* p2pTasks[2] = { recv, send };`，反的。
- 然后`addP2pToPlan`将具体任务放到plan内，大致就是planner内一对send recv组合位一条`ncclDevWorkP2p`，并通过`addWorkBatchToPlan`放到当前plan，并看是否跨NIC buffer传输，生成相应的proxyOp做辅助调度。
```c++
// enqueue.cc 内的addP2pToPlan API
static ncclResult_t addP2pToPlan( ...) {
	for (int part=0; part < nChannelsMax; part++) {
				// ........
        protoLL[dir] &= conn->conn.buffs[NCCL_PROTO_LL] != nullptr;
        network[dir] |= conn->transportComm == (dir ? &netTransport.send : &netTransport.recv);
        proxySameProcess[dir] &= conn->proxyConn.sameProcess;
      }
    }
  // 计算了下面两样
  1.netRegistered[dir] / 2.ipcRegistered[dir]
  
  struct ncclWorkList* workNode = ncclMemoryStackAllocInlineArray<ncclWorkList, ncclDevWorkP2p>(&comm->memScoped, 1);
  workNode->workType = ncclDevWorkTypeP2p;
  workNode->size = sizeof(struct ncclDevWorkP2p);
  ncclIntruQueueEnqueue(&plan->workQueue, workNode);
  uint32_t workOffset = plan->workBytes;
  plan->workBytes += sizeof(struct ncclDevWorkP2p);
  struct ncclDevWorkP2p* work = (struct ncclDevWorkP2p*)(workNode+1);
  // ... 一堆填写的代码
  struct ncclProxyOp proxyOps[2] = {};
  // ... 一堆填写的代码

  for (int part=0; part < nChannelsMax; part++) {
  int channelId = ncclP2pChannelForPart(comm->p2pnChannels, base, part);
  addWorkBatchToPlan(...);
  addProxyOpIfNeeded(...);
	}	
}	
```
    - 先看了一些辅助信息决定后面是否注册buffer和用什么协议通信，`protoLL[0/1]` 表示当前这对任务是否可以使用 LL 协议（更快）；`network[]` 表示这是否是跨节点通信；`proxySameProcess[]` 表示是否在同一个进程内。
    - 要是1.netRegistered这个东西是true，那就调用`ncclRegisterP2pNetBuffer`跨节点网络通信。2.ipcRegistered是true就得用IPC buffer走`ncclRegisterP2pIpcBuffer` api完成跨GPU同节点通信，并写到后面的`work`和`proxyOp`。（这里一大串代码当中穿插了chunkDataSize[dir]，nChannels[dir]，stepSize等等的计算，为了后面每个channel上分配多大数据用于通信）
    - 接下来填写`ncclDevWorkP2p`到plan内，将前面send/recv rank、地址、大小、chunk 大小、协议类型、是否注册 buffer 都填进 `work`，然后插入 `plan->workQueue` 中。这里还对跨NIC生成proxyOp，并把 chunk 步数、offset、buffer handle 等等填进去。
    - for loop给每个channel内分配batch任务和对应的proxyOp。
综上，`ncclDevWorkP2p` 就是 "这个 rank 要干的一对活（收+发）"，用work描述。为什么已经是一对p2p任务了还要编出batch再to plan，因为：

| `work` | `ncclDevWorkP2p` | 描述了一对 p2p（发送/接收）任务的实际内容（地址、大小、谁发谁收） |
| --- | --- | --- |
| `batch` | `ncclDevWorkBatch` | 描述 GPU kernel 一次能执行多少 work，类型（p2p/coll），在哪个 channel |

现在，work 在 plan 的 workQueue（供后续 kernel launch 使用），channel内的workBatchQueue内有当前 channel 对这个 `work` 的 batch 组织（也可以理解成 launch 批次/分组信息）。
```c++
// scheduleP2pTasksToPlan API的剩下一小部分
if (send != nullptr) {
  ncclIntruQueueDequeue(&peers[sendRank].sendQueue);
  ncclIntruQueueEnqueue(&plan->p2pTaskQueue, send);
  comm->planner.nTasksP2p -= 1;
}
if (recv != nullptr) {
  ncclIntruQueueDequeue(&peers[recvRank].recvQueue);
  ncclIntruQueueEnqueue(&plan->p2pTaskQueue, recv);
  comm->planner.nTasksP2p -= 1;
}
// scheduleP2pTasksToPlan至此结束
```
plan->workQueue / plan->p2pTaskQueue 等数据结构都准备好了。

现在回到`ncclLaunchPrepare` API内剩下的代码。

让主 launchStream 等待所有参与的 user stream 上的任务完成，

```c++
ncclResult_t ncclLaunchPrepare(struct ncclComm* comm) {
	//....
	struct ncclKernelPlan* planHead = ncclIntruQueueHead(&planner->planQueue);
  planner->unlaunchedPlansHead = planHead;
  
	cudaStream_t launchStream = planner->streams->stream;
  cudaStream_t deviceStream, launchOrder;
	for (struct ncclCudaStreamList* l=planner->streams->next; l != nullptr; l = l->next) {
	  CUDACHECKGOTO(cudaEventRecord(comm->sharedRes->scratchEvent, l->stream), result, failure);
    CUDACHECKGOTO(cudaStreamWaitEvent(launchStream, comm->sharedRes->scratchEvent, 0), result, failure);
	}
	...
		
}
```

首先重点是记住这里的planner->unlaunchedPlansHead是planner->planQueue这个队列的头（后面真正launch的时候会用到）。让主 launchStream 等待所有参与的 user stream 上的任务完成，强行设置了stream依赖。也就是说你在groupStart和groupEnd之内自定义的其他stream会被加入planner→streams，streams里面第一个stream会等待其他stream上的时间完成再执行kernel。

回到group.cc的`dolaunches`代码：

```c++
static ncclResult_t doLaunches(struct ncclComm* head) {
  // ... 准备完毕了
  if (useBarrier) ncclCommIntraBarrierIn(comm, 1);
      comm = comm->groupNext;
      
  while (true) { // Iterate rounds of launches for clique.
      bool moreRounds = false;
      comm = cliqueHead;
      do { // Iterate clique members.
        struct ncclComm* next = comm->groupNext;
        if (useBarrier) {
          // Barrier reduction result tells us if this was the final round.
          moreRounds = 0 != ncclCommIntraBarrierOut(comm);
        } else {
          moreRounds |= comm->planner.unlaunchedPlansHead != nullptr;
        }
        if (moreRounds) {
          // Pop next unlaunched kernel
          struct ncclKernelPlan* plan = comm->planner.unlaunchedPlansHead;
          if (plan != nullptr) {
            comm->planner.unlaunchedPlansHead = plan->next;
            CUDACHECKGOTO(cudaSetDevice(comm->cudaDev), result, failure);
            NCCLCHECKGOTO(ncclLaunchKernelBefore_NoUncapturedCuda(comm, plan), result, failure);
            NCCLCHECKGOTO(ncclLaunchKernel(comm, plan), result, failure);
          }
          // Barrier reduction input indicates if we require further rounds.
          if (useBarrier) ncclCommIntraBarrierIn(comm, comm->planner.unlaunchedPlansHead != nullptr ? 1 : 0);
          if (plan != nullptr) {
            NCCLCHECKGOTO(ncclLaunchKernelAfter_NoCuda(comm, plan), result, failure);
          }
        } else { // Final round.
          CUDACHECKGOTO(cudaSetDevice(comm->cudaDev), result, failure);
          NCCLCHECKGOTO(ncclLaunchFinish(comm), result, failure);
        }
        comm = next;
      } while (comm != cliqueNextHead);
      if (!moreRounds) break;
    }
    cliqueHead = cliqueNextHead;
  } while (cliqueHead != nullptr);
}
```

一个comm内的多个p2p任务结束后要barrier一下再去启动下一个comm（sibling / clique comm）。一共三个核心发射，`ncclLaunchKernelBefore_NoUncapturedCuda`，`ncclLaunchKernel`，`ncclLaunchKernelAfter_NoCuda`。

- 第一个：这里底层是将comm和plan放到uploadWork()函数内部，主要是将plan中的数据准备好，内核直接使用这些数据进行计算。这里会根据workStorageType确定存储类型，但是这个是怎么计算得出的暂时不详。先细看如果是ncclDevWorkStorageTypeFifo类型的情况。

## 4 模拟

abstract：假设4个rank的alltoall任务

官方的实现：

```c++
NCCLCHECK(ncclGroupStart());
  for (int r=0; r<nRanks; r++) {
    NCCLCHECK(ncclSend(((char*)sendbuff)+r*rankOffset, count, type, r, comm, stream));
    NCCLCHECK(ncclRecv(((char*)recvbuff)+r*rankOffset, count, type, r, comm, stream));
  }
NCCLCHECK(ncclGroupEnd());
```

1. 第一步收集所有send和recv任务放到planner的sendQue和RecvQue。具体操作在taskAppend()内；rank0在alltoall中的p2p任务总计就是下面三对send recv。
| rank0 peers | **sendQueue** | **recvQueue** |
| --- | --- | --- |
| ~~0~~ | ~~“S0→0”  自发后面会跳过~~ | ~~“R0←0” 自收后面会跳过~~ |
| 1 | “S0→1” | “R0←1” |
| 2 | “S0→2” | “R0←2” |
| 3 | “S0→3” | “R0←3” |

这里rank1在alltoall中的p2p任务如下（rank1发rank1没了，自发自收跳过）：

| rank1 peers | sendQueue | recvQueue |
| --- | --- | --- |
| 0 | “S1→0” | “R1←0” |
| 2 | “S1→2” | “R1←2” |
| 3 | “S1→3” | “R1←3” |

同理，rank2和rank3的发和收类似上面。。。。。。
2. 跳过辅助的操作，现在直接到scheduleP2pTasksToPlan()内。由for循环内的迭代变量round查p2pSchedule表（见第5节对这个表的详解），上面rank0到rank4收集到的任务会变。现在列举round=1时，四个rank上的第一次send和recv任务会变为什么：
```c++
// scheduleP2pTasksToPlan（）查表的操作
int sendRank = comm->p2pSchedule[round].sendRank;
int recvRank = comm->p2pSchedule[round].recvRank;
struct ncclTaskP2p* send = ncclIntruQueueHead(&peers[sendRank].sendQueue);
struct ncclTaskP2p* recv = ncclIntruQueueHead(&peers[recvRank].recvQueue);
```
    1. 结合第五节表得出round1四个rank的发和收的任务如下：
| rank | `sendPeer` | 从 **sendQueue** 取出的卡 | `recvPeer` | 从 **recvQueue** 取出的卡 |
| --- | --- | --- | --- | --- |
| 0 | **1** | “S0→1” | 3 | “R0←3” |
| 1 | **2** | “S1→2” | 0 | “R1←0” |
| 2 | **3** | “S2→3” | 1 | “R2←1” |
| 3 | **0** | “S3→0” | 2 | “R3←2” |
    2. `struct ncclTaskP2p* p2pTasks[2] = { recv, send };` 会将当前rank的任务变成{“R0←3”, “S0→1”}。这里的`ncclTaskP2p`进入`addp2ptoPlan` 对每个rank当前**“收谁 + 发谁”** 写进同一个 work，得到1条`ncclDevWorkP2p`（里面的sendRank = 1， recvRank = 3）。这个会被重新排布为 **workQueue / p2pTaskQueue**，并把需要给 GPU 的原始参数序列化到 **workFifo。**
    3. 接着`uploadWork()` + `ncclLaunchKernelBefore_*` 把plan 中的 workFifo 拷到 **comm->devWorkFifo**（UVA 或 `cudaMemcpyAsync`），并生成 `kernelArg` 结构。
这两步的操作:
```c++
host: addP2pToPlan()         ← 填这些字段
uploadWork()                 ← 把 work 写进 FIFO
GPU:  ncclKernel_P2p
  └──── doOneP2p()
          ├─ runSend<Proto>()
          |     ↘ 根据 sendChunkSize/nSendChannels 写多通道
          └─ runRecv<Proto>()
                ↘ 根据 recvChunkSize/nRecvChannels 读多通道
proxy 线程(若启用)
  └──── netSend / netRecv
          ↘ 用 sendNetReg/recvNetReg 判断是否走注册缓冲
```
    4. `ncclLaunchKernel` 
```c++
           ┌──────── workMask (=fifoBytes-1)
kernelArgs │ workBuf (指向同一个 FIFO 映射)
───────────┼─────────────────────────────────────────────── fifoCursor = 起点
batch[0]   │ struct ncclDevWorkBatch  (24 B)  ← channel 0
batch[1]   │ struct ncclDevWorkBatch  (24 B)  ← channel 1
batch[2]   │ struct ncclDevWorkBatch  (24 B)  ← channel 2
───────────┼─────────────────────────────────────────────── fifoCursor = 3×24 = 72
work #0    │ 16 B ncclDevWorkP2p  (ch0, round0)
work #1    │ 16 B ncclDevWorkP2p  (ch1, round1)
work #2    │ 16 B ncclDevWorkP2p  (ch2, round2)
───────────┼─────────────────────────────────────────────── fifoCursor = 72+3×16 = 120
```
        - **batch 数组**：每行告诉 GPU
            - 这批 work 属于哪条 **channel**
            - 从 FIFO **offsetBase** 处开始
            - `offsetBitset` 标哪些 slot 已经塞了 work
        - **work 数组**：真正的指令，每条 16 B，对齐到 16。
其中包含
            - `directionMask`（SEND / RECV）
            - `sendRank/recvRank`
            - 每方向 `conn` 地址、chunkSize 等
偏移量都在 uploadWork() 里加上 **fifoCursor**，于是变成 FIFO 内的绝对地址。


## 5 p2p schedule

init.cc内对这个调度表的初始化的代码(nccl 2.22版本之后)

```c++
  do { // Build p2p schedule
    int node = comm->node;
    int nNodes = comm->nNodes;
    int nRanks = comm->nRanks;
    int local = comm->localRank;
    int nLocals = comm->maxLocalRanks;
    struct ncclNodeRanks* nodeRanks = comm->nodeRanks;
    bool flat = false;
    for (int node = 0; node < nNodes; node++) {
      if (nodeRanks[node].localRanks != nLocals) {
        flat = true;
        nNodes = 1; node = 0;
        nLocals = nRanks; local = rank;
        break;
      }
    }
    int nNodesPow2 = pow2Up(nNodes);
    int nLocalsPow2 = pow2Up(nLocals);
    comm->p2pSchedule = ncclMemoryStackAlloc<ncclComm::P2pSchedulePair>(&comm->memPermanent, nRanks);
    comm->planner.peers = ncclMemoryStackAlloc<ncclKernelPlanner::Peer>(&comm->memPermanent, nRanks);
    uint32_t nodeRound = 0;
    uint32_t nodeDelta = 0;
    int round = 0;
    // When enumerating peer deltas we use the quadratic formula (x*x+x)/2 mod N.
    // Since that formula only produces valid permutations when N is a pow of 2,
    // we let N = pow2Up(n) and filter out results greater-eq to n.
    // Example sequence for 16 ranks: 0, 1, 3, 6, 10, 15, 5, 12, 4, 13, 7, 2, 14, 11, 9, 8
    do {
      if (nodeDelta < nNodes) { // Filter nonsensical node deltas
        int sendNode = (node + nodeDelta) % nNodes;
        int recvNode = (node - nodeDelta + nNodes) % nNodes;
        uint32_t localRound = 0;
        uint32_t localDelta = 0;
        do {
          if (localDelta < nLocals) { // Filter nonsensical node-local deltas
            int sendLocal = (local + localDelta) % nLocals;
            int recvLocal = (local - localDelta + nLocals) % nLocals;
            comm->p2pSchedule[round].sendRank = flat ? sendLocal : nodeRanks[sendNode].localRankToRank[sendLocal];
            comm->p2pSchedule[round].recvRank = flat ? recvLocal : nodeRanks[recvNode].localRankToRank[recvLocal];
            round += 1;
          }
          localRound += 1;
          localDelta = (localDelta + localRound) & (nLocalsPow2 - 1); // Quadratic update
        } while (localRound != nLocalsPow2);
      }
      nodeRound += 1;
      nodeDelta = (nodeDelta + nodeRound) & (nNodesPow2 - 1); // Quadratic update
    } while (nodeRound != nNodesPow2);

    if (round != nRanks) {
      WARN("P2p schedule creation has bugs.");
      ret = ncclInternalError;
      goto fail;
    }
  } while (0);
```

中间这个do循环，是表示节点间的循环，nodeRound从0迭代到nNodesPow2（这个是nNodes的最小二次幂）。最内层的do循环是节点内的循环，计算了`localDelta = (localDelta + localRound) & (nLocalsPow2 - 1)`来算出每次round当前rank发给谁（sendLocal）和接收谁（recvLocal）。假设四个rank：[计算这个最小二次幂就是为了算的更快，等价于直接mod 4，但是用这里是& 3]。下面是所有迭代展开后p2p schedule表初始化后每个rank的任务：

| Rank | round 0 | round 1 | round 2 | round 3 |
| --- | --- | --- | --- | --- |
| **0** | (0, 0) | (1, 3) | (3, 1) | (2, 2) |
| **1** | (1, 1) | (2, 0) | (0, 2) | (3, 3) |
| **2** | (2, 2) | (3, 1) | (1, 3) | (0, 0) |
| **3** | (3, 3) | (0, 2) | (2, 0) | (1, 1) |

(ps: 括号内第一个值是send who，第二个值是recv who，这俩通过下面的公式算出来)

```c
int sendLocal = (local + localDelta) % nLocals;  // 发送的本地rank
int recvLocal = (local - localDelta + nLocals) % nLocals;  // 接收的本地rank
```

## 6 introduction

### 6.1 FIFO

nccl的comm中存储即将device执行`ncclDevWork`数据的一块共享区域。多个kerne启动使用的“任务指令”就是放在这个FIFO内，防止多次mlloc和memcpy。这是一个环形缓冲区，使用`mask`快速wrap-around（回到起点）。

### 6.2 ncclDevKernelArgs

```c++
struct alignas(16) ncclDevKernelArgs {
  struct ncclDevComm* comm; //指向设备端通信上下文 ncclDevComm，包含 rank、channels、buffers 等设备端状态
  uint64_t channelMask; //标记哪些 channel 启用了（64 位掩码，最多 64 个 channel）
  enum ncclDevWorkStorageType workStorageType;//表示工作缓冲区存储类型（Args、Fifo、Persistent）
  uint32_t workMask;//用于实现 FIFO wrap-around 的掩码值（通常为 size-1）
  void* workBuf;//指向设备端的工作数据数组（由 host 在 uploadWork 中准备好并复制过去）
  // A channel's first batch is at `blockIdx.x`. Use `nextJump` to follow rest of list.
  // struct ncclDevWorkBatch batches[];
};
```

## 7. Figure

![[V&NCCL/NCCL-start/excalidraw/image 4.png]]
