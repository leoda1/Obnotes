---

---
## 1. PassSm Problems：

开启`ncclParamPassSm`在正常训练的时候如果出现coll任务，那么就会直接coredumps。而在nccltest中只有单个任务长时间测试是没有问题的。

## 2. Analysis：

### a. 任务顺序

在`ncclLaunchPrepare` 内，`nWorkBudget` 是每个内核都有**工作预算限制。**并且说了Drain coll tasks first. This is essential since we partition tasks based on the work budget and p2p work isn't collective. If we were to drain p2p first, the place where we cut the kernel could vary by rank which would cause the "shortest channel first" channel picker to have divergent results. 先P2P会破坏kernel执行时使用的channel，P2P会用不同的channel，通道的负载量`chans[c].collBytes` 会增加，会导致所有rank的通道负载不同。

> [!note]+ `ncclLaunchPrepare`
> ```c++
> 
> ncclResult_t ncclLaunchPrepare(struct ncclComm* comm) {
> 		if(ncclParamPassSm() && tasks->nTasksP2p > 0) {
> 		    NCCLCHECK(preScheduleP2pUseNokernel(comm));
> 		}
> 		if (tasks->nTasksColl + tasks->nTasksP2p != 0) {
> 			  do {
> 			    struct ncclKernelPlan* plan = ncclMemoryPoolAlloc<struct ncclKernelPlan>(&comm->memPool_ncclKernelPlan, &comm->memPermanent);
> 			    ncclIntruQueueEnqueue(&comm->planQueue, plan);
> 			    nPlans += 1;
> 			    plan->comm = comm;
> 			    plan->reclaimer.fn = reclaimPlan;
> 			    plan->persistent = persistent;
> 			
> 			    // Non-persistent kernels fill up at most half of our fifo per kernel.
> 			    int nWorkBudget = plan->persistent ? INT_MAX : comm->workFifoDepth/2;
> 			    int nWorkBudgetOld = nWorkBudget;
> 			
> 			    // Drain coll tasks first. This is essential since we partition tasks based
> 			    // on the work budget and p2p work isn't collective. If we were to drain p2p
> 			    // first, the place where we cut the kernel could vary by rank which would
> 			    // cause the "shortest channel first" channel picker to have divergent results.
> 			    if (tasks->nTasksColl != 0) {
> 			      NCCLCHECKGOTO(scheduleCollTasksToPlan(comm, plan, &nWorkBudget), result, failure);
> 			    }
> 			    // And only drain p2p tasks once colls are depleted.
> 			    if (tasks->nTasksColl == 0 && tasks->nTasksP2p != 0) {
> 			      NCCLCHECKGOTO(scheduleP2pTasksToPlan(comm, plan, &nWorkBudget), result, failure);
> 			    }
> }
> ```

在`addTunedCollToPlan`内，当后续处理collective时，**least loaded channel选择器**会在不同rank上选择写了会选最低负载的channel。

```c++
// Choose the `nBid` least loaded channels to do the work. This ensures
  // all bids go to different channels in case they need to synchronize.
  least[0] = 0;
  maxIndexInLeast = 0;
  maxBytesInLeast = chans[0].collBytes;
  // Initialize least[] such that the first nBid channels are accounted for.
```

先coll再p2p可以正好**保证内核切分一致性。**

### b. NCCL Stream Cleanup:

首先，nccl 对stream的管理流程大致为User Streams → Device Stream → Launch Stream → GPU Kernel。具体包括：

> [!note]+ `**ncclLaunchPrepare**`**中的Stream依赖建立**
> ```c++
> ncclResult_t ncclLaunchPrepare(struct ncclComm* comm) {
>   ncclResult_t result = ncclSuccess;
>   struct ncclTasks* tasks = &comm->tasks;
>   if(ncclParamPassSm() && tasks->nTasksP2p > 0) {
>     NCCLCHECK(preScheduleP2pUseNokernel(comm));
>   }
>   bool persistent = ncclCudaGraphValid(tasks->capturingGraph);
>   int nPlans = 0; // plan的计数器
> ```
> 
> tasks是任务队列的指针，包含所有p2p和coll任务。无核开启的话检查一下P2P任务直接处理避免launchkernel。`persistent` 检查当前cuda graph模式确定是否**持久化**处理。
> 
> ```c++
> // Poll for callbacks sent to us from other threads. Typically these free
> // resources from to our memory pools.
> NCCLCHECK(ncclCommPollCallbacks(comm, /*waitSome=*/false));
> // We already have one frame present which holds all of our tasks (which we
> // are about to schedule). Now push an additional frame for allocating
> // work structs (see appendWorkElem() variants all use scoped allocation).
> ncclMemoryStackPush(&comm->memScoped);
> ```
> 
> 先轮询其他线程的回调，应该是在处理之前kernel完成后的`reclaimPlan`回调（释放内存池的资源），给下面有核的p2p和coll新任务腾出空间。具体实现:
> 
> ```c++
> inline ncclResult_t ncclCommPollCallbacks(struct ncclComm* comm, bool waitSome) {
>   ncclResult_t result = ncclSuccess;
>   struct ncclCommCallback* cb = ncclIntruQueueMpscDequeueAll(&comm->callbackQueue, waitSome);
>   while (cb != nullptr) {
>     struct ncclCommCallback* next = cb->next;
>     ncclResult_t res1 = cb->fn(comm, cb); // may reclaim memory of cb
>     if (res1 != ncclSuccess) result = res1;
>     cb = next;
>   }
>   NCCLCHECK(result);
>   return ncclSuccess;
> }
> ```
> 
> `cb` 取出所有待处理回调，选用cb->fn，即reclaimPlan执行各种清理。（这里的Mpsc队列在其他多个地方由生产者放了回调）
> 
> `ncclMemoryStackPush` 负责推入新的内存栈帧，为了分配`ncclWork` 结构体（是`appendWorkElem()`的变体，使用scoped allocation[???没看懂]），在后面`ncclLaunchFinish`中会被pop掉。
> 
> ```c++
> if (tasks->nTasksColl + tasks->nTasksP2p != 0) {
>   do {
>     struct ncclKernelPlan* plan = ncclMemoryPoolAlloc<struct ncclKernelPlan>(&comm->memPool_ncclKernelPlan, &comm->memPermanent);
>     ncclIntruQueueEnqueue(&comm->planQueue, plan);
>     nPlans += 1;
>     plan->comm = comm;
>     plan->reclaimer.fn = reclaimPlan;                    // 设置cleanup回调函数
>     plan->persistent = persistent;
> 
>     // Non-persistent kernels fill up at most half of our fifo per kernel.
>     int nWorkBudget = plan->persistent ? INT_MAX : comm->workFifoDepth/2;
>     int nWorkBudgetOld = nWorkBudget;
> 
>     // Drain coll tasks first...
>     if (tasks->nTasksColl != 0) {
>       NCCLCHECKGOTO(scheduleCollTasksToPlan(comm, plan, &nWorkBudget), result, failure);
>     }
>     // And only drain p2p tasks once colls are depleted.
>     if (tasks->nTasksColl == 0 && tasks->nTasksP2p != 0) {
>       NCCLCHECKGOTO(scheduleP2pTasksToPlan(comm, plan, &nWorkBudget), result, failure);
>     }
>     
>     finishPlan(plan);
>   } while (tasks->nTasksColl + tasks->nTasksP2p != 0);
> ```
> 
> 从内存池分配一个`ncclKernelPlan` 结构体，并加入到计划队列。plan数加1，设置**核心回收函数为**`**reclaimPlan**`**。**然后就直接先处理coll再处理p2p。在`finishPlan`内会标记最后的工作元素，以及`hasProxyOps |= !ncclIntruQueueEmpty(&plan->channels[c].proxyOpQueue);`，会看钱现在这个plan的`channels[c]`上有没有op。
> 
> ```c++
> for (int c=0; c < MAXCHANNELS; c++) {
>     struct ncclWorkList* tail = ncclIntruQueueTail(&plan->channels[c].workQueue);
>     if (tail != nullptr) {
>       channelUbound = c+1;          // 更新通道上界
>       channelCount += 1;            // 增加通道计数
>       channelMask |= 1ull<<c;       // 设置通道位掩码
>       tail->work.header.isLast = 1; // 标记最后工作元素（关键cleanup标志）
>       finishWork(&tail->work);      // 完成工作设置（P2P特殊处理）
>     }
>     hasProxyOps |= !ncclIntruQueueEmpty(&plan->channels[c].proxyOpQueue);
>   }
> ```
> 
> `tail->work.header.isLast = 1`告诉GPU这是当前channel最后一个工作，完成后就发出cleanup回调。这和`uploadWork`中设置的`q->work.header.doneAcks = ix+1;` 对应。调用`finishWork`完成P2P工作设置(并行组，warp开始位置，warp数量)，之后`hasProxyOps`检查是否需要host stream cleanup。再后面`finishPlan`内遍历工作的channel数量用于后续启动kernel的grid维度。
> 
> ```c++
> struct ncclKernelPlan* planHead = ncclIntruQueueHead(&comm->planQueue);
> comm->unlaunchedPlansHead = planHead;
>     
> cudaStream_t launchStream = tasks->streams->stream;
> NCCLCHECKGOTO(ncclStrongStreamAcquire(tasks->capturingGraph, &comm->sharedRes->deviceStream), result, failure);
> 
> // Create dependency for device stream on user streams. First from extra user
> // streams to deviceStream. Then deviceStream to first user stream.
> for (struct ncclCudaStreamList* l=tasks->streams->next; l != nullptr; l = l->next) {
>   NCCLCHECKGOTO(ncclStrongStreamWaitStream(tasks->capturingGraph, &comm->sharedRes->deviceStream, l->stream), result, failure);
> }
> NCCLCHECKGOTO(ncclStrongStreamWaitStream(tasks->capturingGraph, launchStream, &comm->sharedRes->deviceStream), result, failure);
> ```
> 
> 先设置了类似dummyhead的节点，是未启动planHead。然后分别获得用户stream是`launchStream`，设备stream是`comm->sharedRes->deviceStream`。
> 
> for loop内建立extra用户stream → deviceStream的依赖：
> 
> - 遍历除第一个stream外的所有用户stream
> - 让deviceStream等待每个额外的用户stream
> - 确保所有用户操作完成后deviceStream才能继续
> 
> 还建立了一个launchStream ← deviceStream的依赖
> 
> - launchStream等待deviceStream
> - 形成双向依赖：用户streams → deviceStream → launchStream
> 
> ```c++
> if (persistent || comm->persistentRefs != 0 || ncclCudaLaunchBlocking) {
>   // We have to launch host tasks to push proxy args. We are careful to only
>   // do this if necessary since host tasks impose a high performance cost in CUDA.
>   bool acquired = false;
>   for (struct ncclKernelPlan* plan=planHead; plan != nullptr; plan = plan->next) {
>     if (plan->hasProxyOps) {
>       if (!acquired) {
>         acquired = true;
>         NCCLCHECKGOTO(ncclStrongStreamAcquire(tasks->capturingGraph, &comm->sharedRes->hostStream), result, failure);
>       }
>       NCCLCHECKGOTO(ncclStrongStreamLaunchHost(tasks->capturingGraph, &comm->sharedRes->hostStream, hostStreamPlanCallback, plan), result, failure);
>     }
>   }
>   if (acquired) {
>     // Make to-be-launched kernels dependent on just-launched host stream tasks.
>     NCCLCHECKGOTO(ncclStrongStreamWaitStream(tasks->capturingGraph, launchStream, &comm->sharedRes->hostStream), result, failure);
>     NCCLCHECKGOTO(ncclStrongStreamRelease(tasks->capturingGraph, &comm->sharedRes->hostStream), result, failure);
>   }
> }
> 
> if (persistent) {
>   comm->persistentRefs += nPlans;
>   NCCLCHECKGOTO(ncclCudaGraphAddDestructor(tasks->capturingGraph, persistentDestructor, (void*)planHead), result, failure);
> }
> ```
> 
> 有`hasProxyOps`就会设置host回调，注释说这个只能在十分需要的时候获取`hostStream`，还说开CUDA上host任务开销非常大。这个回调（`reclaimer` ）具体API就是`hostStreamPlanCallback`   去触发proxy资源的清理（异步）。之后又建立了**launchStream对hostStream的依赖：**
> 
> - 确保kernel等待host任务完成
> - 释放hostStream资源
> 
> > [!note]+ 刚刚`hostStreamPlanCallback`的代码：
> > `hostStreamPlanCallback`内实际处理函数是`hostStreamPlanTask` ，这里包含三个操作：
> > 
> > ```c++
> > static ncclResult_t hostStreamPlanTask(struct ncclComm* comm, struct ncclKernelPlan* plan) {
> >   NCCLCHECK(uploadProxyOps(comm, plan));    // ①上传proxy操作到proxy线程队列
> >   NCCLCHECK(ncclProxyStart(comm));          // ②启动proxy线程处理
> >   if (!plan->persistent) {
> >     ncclIntruQueueMpscEnqueue(&comm->callbackQueue, &plan->reclaimer);  // ③安排plan回收
> >   }
> >   return ncclSuccess;
> > }
> > ```
> > 
> > - `uploadProxyOps()` 内调用`ncclProxySaveOp` 保存到proxy线程队列里，里面检查了`plan->persistent` （不是持久内核就直接释放操作内存）。
> > - `ncclProxyStart` 内会调用`ncclProxyPost` 把操作队列`comm->proxyState->proxyOps`  post到proxy线程，P2P传输完成就会调用`progressOps`检测是否完成，然后用`p2pSendProxyFree/p2pRecvProxyFree`释放资源并用`removeOp`移除操作。
> > - 这里不是持久内核就`ncclIntruQueueMpscEnqueue` ，触发`reclaimer`，主线程就去回收`plan` 
> 
> 持久化这里用了`persistentDestructor` 确保cuda graph销毁的时候会触发`reclaimer` 回调。
> 
> 回到ncclLaunchPrepare内，接下来就是：
> 
> ```c++
> if (false) {
> failure:
>   ncclMemoryStackPop(&comm->memScoped); // deallocate ncclWork's
> }
> ```
> 
> 失败的话就清理刚刚的内存栈帧。至此ncclLaunchPrepare结束。

> [!note]+ `**ncclLaunchKernelBefore**`建立cleanup的"回调契约"
> ```c++
> ncclResult_t ncclLaunchKernelBefore_NoUncapturedCuda(struct ncclComm* comm, struct ncclKernelPlan* plan) {
>   // This code is called after we've checked in to the intra-process barrier
>   // but before launching the kernel. We are not allowed to call CUDA unless the
>   // kernel launch is captured.
>   NCCLCHECK(uploadWork(comm, plan));
>   return ncclSuccess;
> }
> ```
> 
> 在intra-process barrier之后，kernel launch之前会`uploadWork` （上传`plan`内所有`work`到GPU可访问的内存区域）。
> 
> ```c++
> static ncclResult_t uploadWork(struct ncclComm* comm, struct ncclKernelPlan* plan) {
>   bool persistent = plan->persistent;          // 是否为持久化计划
>   int channelUbound = plan->channelUbound;     // 使用的通道上界
>   int nWork = 0;
>   
>   // 计算总工作数量
>   for (int c=0; c < channelUbound; c++) nWork += plan->channels[c].nWork;
> 
>   struct ncclWork* workHeap;
>   if (!persistent) {
>     workHeap = comm->workFifoHeap;              // 非持久化：使用共享工作队列
>   } else {
>     workHeap = ncclMemoryStackAlloc<struct ncclWork>(&comm->memScoped, nWork);  // 持久化：分配临时内存
>   }
>   ......
>   waitWorkFifoAvailable(comm, ixSent + nWork);
>   ......
> 	for (int c=0; c < channelUbound; c++) {
>     struct ncclWorkList* q = ncclIntruQueueHead(&plan->channels[c].workQueue);
>     uint32_t ix = ixHead + channelsWithWork;  // 第一个工作的偏移 = 下面有工作的通道数
>     channelsWithWork += q != nullptr ? 1 : 0;
>     
>     while (q != nullptr) {
>       if (q->next != nullptr) {
>         // 设置指向下一个工作的偏移
>         q->work.header.workNext = int32_t(ixSent & ixMask) - int32_t(ixHead & ixMask);
>       } else {
>         // 最后一个工作：设置完成标志
>         q->work.header.inFifo = !persistent ? 1 : 0;
>         q->work.header.doneAcks = ix+1;  // 告诉通道确认ix+1，表示所有到ix的槽都已消费
>         comm->channels[c].workFifoSent = ix+1;
>       }
>       
>       // **关键**：将工作复制到heap
>       workHeap[ix & ixMask] = q->work; // C++结构体赋值
>       q = q->next;
>       if (q != nullptr) ix = ixSent++;
>     }
>   }
> ```
> 
> | 模式 | 内存分配 | 数据传输 | 适用场景 |
> | --- | --- | --- | --- |
> | **非持久化** | 共享FIFO | 直接写入 | 普通操作 |
> | **持久化** | 专用GPU内存 | cudaMemcpy | CUDA图捕获 |

> [!note]+ `ncclLaunchKernel` 启动内核
> ```c++
> ncclResult_t ncclLaunchKernel(struct ncclComm* comm, struct ncclKernelPlan* plan) {
>   struct ncclTasks* tasks = &comm->tasks;
>   void *fn = plan->kernelFn;
>   cudaStream_t launchStream = tasks->streams->stream;
>   ...... //一些内核参数
> ```
> 
> 从tasks中获取启动流，其他就是kernel<<<这里的一些常规参数>>>。tasks->streams->stream 是**第一个用户流**，这是在ncclLaunchPrepare中设置的主要启动流。剩下就是看当前cuda版本，是否支持SM90+的集群调度，以及是否支持内存同步，真正launch就是一行代码：
> 
> `CUDACHECK(cudaLaunchKernel(fn, grid, block, args, smem, launchStream));` 

> [!note]+ `**ncclLaunchKernelAfter_NoCuda**`触发reclaimer机制
> ```c++
> ncclResult_t ncclLaunchKernelAfter_NoCuda(struct ncclComm* comm, struct ncclKernelPlan* plan) {
>   if (!(plan->persistent || comm->persistentRefs != 0 || ncclCudaLaunchBlocking)) {
>     // 路径1：不使用host stream进行proxy操作和回收提交
>     NCCLCHECK(hostStreamPlanTask(comm, plan));
>   } else {
>     // 路径2：使用host stream进行proxy操作和回收提交
>     // 只有有proxy操作的plan才会在ncclLaunchPrepare中推送回调
>     // 由于非持久化plan也需要回收，我们必须在这里处理
>     if (!plan->persistent && !plan->hasProxyOps) {
>       ncclIntruQueueMpscEnqueue(&comm->callbackQueue, &plan->reclaimer);
>     }
>   }
>   return ncclSuccess;
> }
> ```
> 
> `ncclLaunchPrepare` 内的hostStreamPlanCallback和这里的api的关系是：hostStreamPlanCallback >> hostStreamPlanTask >> ncclIntruQueueMpscEnqueue。
> 
> ```c++
> static ncclResult_t hostStreamPlanTask(struct ncclComm* comm, struct ncclKernelPlan* plan) {
>   NCCLCHECK(uploadProxyOps(comm, plan));
>   NCCLCHECK(ncclProxyStart(comm));
>   if (!plan->persistent) {
>     // Notify main thread of our reclaiming. This will reclaim plan concurrently.
>     ncclIntruQueueMpscEnqueue(&comm->callbackQueue, &plan->reclaimer);
>   }
>   return ncclSuccess;
> }
> 
> static void CUDART_CB hostStreamPlanCallback(void *plan_) {
>   NVTX3_FUNC_RANGE_IN(nccl_domain);
>   struct ncclKernelPlan* plan = (struct ncclKernelPlan*)plan_;
>   ncclResult_t result = hostStreamPlanTask(plan->comm, plan);
>   if (result != ncclSuccess) {
>     WARN("hostStreamPlanCallback() failed : %s", ncclGetErrorString(result));
>   }
> }
> ```
> 

> [!note]+ `**ncclLaunchFinish**`中的Stream清理
> ```c++
> // src/enqueue.cc:1613-1648
> ncclResult_t ncclLaunchFinish(struct ncclComm* comm) {
>   ncclResult_t result = ncclSuccess;
>   struct ncclTasks* tasks = &comm->tasks;
>   tasks->workBytesTotal = 0;
> 
>   // 释放ncclWork内存。这个frame在ncclLaunchPrepare成功时存在，
>   // 如果ncclLaunchPrepare失败我们就不会到这里
>   ncclMemoryStackPop(&comm->memScoped);
> ```
> 
> 这里重制了计数器，确保下次操作的work数量计算正确。并释放ncclLaunchPrepare中分配的工作结构体内存。接着：
> 
> ```c++
> if (!ncclIntruQueueEmpty(&comm->planQueue)) {
>     // 将队列重置为空，但不销毁plans，因为它们会通过callbackQueue发回给我们进行回收
>     ncclIntruQueueConstruct(&comm->planQueue);
> ```
> 
> 将planQueue清空，其中plans已经通过callbackQueue回收了。
> 
> ```c++
> 		cudaStream_t launchStream = tasks->streams->stream; // 第一个用户流用于launch
> 		// 为deviceStream创建对launchStream的依赖。我们知道deviceStream
>     // 自从launchStream等待它以来没有被修改（在ncclLaunchPrepare中），
>     // 等价于launchStream包含了它。
>     NCCLCHECKGOTO(ncclStrongStreamWaitStream(tasks->capturingGraph, 
>                   &comm->sharedRes->deviceStream, launchStream, 
>                   /*b_subsumes_a=*/true), result, resume1);
> ```
> 
> **建立DeviceStream→LaunchStream依赖**，之前在ncclLaunchPrepare中，launchStream已经等待了deviceStream，现在可以安全地让deviceStream等待launchStream，而不会造成死锁。
> 
> ```c++
> resume1:
>     // 为其他用户流（跳过launch stream）创建对deviceStream的依赖。
>     // 同样，用户流自从deviceStream等待它们以来没有被触碰，
>     // 所以我们可以说它们被deviceStream包含。
>     struct ncclCudaStreamList* sl = tasks->streams->next;
>     tasks->streams = nullptr; // 重置comm->tasks.streams为空
>     while (sl != nullptr) {
>       NCCLCHECKGOTO(ncclStrongStreamWaitStream(tasks->capturingGraph, 
>                     sl->stream, &comm->sharedRes->deviceStream, 
>                     /*b_subsumes_a=*/true), result, resume2);
>     resume2:
>       sl = sl->next;
>     }
> ```
> 
> **建立其他UserStreams→DeviceStream依赖，**sl保存用户stream的next流，然后重置comm->tasks.streams为空。让这个sl流去依赖这个DeviceStream。
> 
> ```c++
> 		NCCLCHECKGOTO(ncclStrongStreamRelease(tasks->capturingGraph, 
> 		                  &comm->sharedRes->deviceStream), result, resume3);
> resume3:;
> }
> ```
> 
>  释放在ncclLaunchPrepare()中获取的device stream。

### c. NCCL Plan Cleanup:

这一步清理具体资源是通过`reclaimPlan()` ，但是穿插在b的五个步骤当中。

> [!note]+ `static ncclResult_t reclaimPlan`，回调触发回收plan。
> ```c++
> static ncclResult_t reclaimPlan(struct ncclComm* comm, struct ncclCommCallback* me) {
>   struct ncclKernelPlan* plan = (struct ncclKernelPlan*)me; // cast from first member `reclaim`
> ```
> 
> `ncclKernelPlan` 第一个成员是`ncclCommCallback reclaimer`，所以可以直接安全把`ncclCommCallback*` 强制转换为 `ncclKernelPlan*` 。
> 
> ```c++
> 	if (plan->persistent) {
> 	    comm->persistentRefs -= 1;
> 	    NCCLCHECK(ncclCudaFree(plan->workHead));
> 	    for (int c=0; c < plan->channelUbound; c++) {
> 	      struct ncclProxyOp* q = ncclIntruQueueHead(&plan->channels[c].proxyOpQueue);
> 	      while (q != nullptr) {
> 	        struct ncclProxyOp* q1 = q->enqNext;
> 	        ncclMemoryPoolFree(&comm->memPool_ncclProxyOp, q);
> 	        q = q1;
> 	      }
> 	    }
> ```
> 
> 先对持久化的内核特殊处理，每调用一次`reclaimPlan` 就会减少一次`comm->persistentRefs`（当前communicator内有多少个persistent plan）。并释放掉GPU上的工作内存，用`ncclCudaFree`释放。
> 
> ProxyOp清理过程：
> 
> - 遍历所有使用的`plan->channelUbound`，并先指定这个通道
> - 每个channel对应的`proxyOpQueue` 内包括所有待处理的proxyOp，这里while会把这个链表结构的proxyOp从头到尾将每个节点还到**内存池** `comm->memPool_ncclProxyOp`。
> 
> ```c++
> 		while (!ncclIntruQueueEmpty(&plan->ipcMemQueue)) {
>       struct ncclPointerList* q = ncclIntruQueueDequeue(&plan->ipcMemQueue);
>       CUDACHECKIGNORE(cudaIpcCloseMemHandle(q->ptr));
>       ncclMemoryPoolFree(&comm->memPool_ncclPointerList, q);
>     }
>     /* free mcHandle */
>     while (!ncclIntruQueueEmpty(&plan->nvlsMcHandleQueue)) {
>       struct ncclNvlsMcHandleList* obj = ncclIntruQueueDequeue(&plan->nvlsMcHandleQueue);
>       NCCLCHECK(ncclNvlsDeregBuffer(&obj->mcHandle, obj->ptr, obj->dev, obj->size));
>       INFO(NCCL_NVLS, "rank %d - deregistered buffer %p on device %d, size %ld", comm->rank, (void*)obj->ptr, obj->dev, obj->size);
>       ncclMemoryPoolFree(&comm->memPool_ncclNvlsHandleList, obj);
>     }
>     while (!ncclIntruQueueEmpty(&plan->collnetHandleQueue)) {
>       struct ncclCollnetHandleList* obj = ncclIntruQueueDequeue(&plan->collnetHandleQueue);
>       NCCLCHECK(ncclCollnetDeregBuffer(comm, obj->proxyconn, obj->collnetHandle));
>       INFO(NCCL_REG, "rank %d - deregistered collnet buffer handle %p, size %ld, buff %p", comm->rank, obj->collnetHandle, obj->size, obj->buffer);
>       ncclMemoryPoolFree(&comm->memPool_ncclCollnetHandleList, obj);
>     }
>     ncclMemoryPoolFree(&comm->memPool_ncclKernelPlan, plan);
>     ...
> ```
> 
> 清理ipc memory, nvls handles, collnet handles等，最后清理plan本身。

在`ncclLaunchPrepare` 有两处调用reclaimer(`ncclCommPollCallbacks`和`hostStreamPlanCallback`)：

```c++
NCCLCHECK(ncclCommPollCallbacks(comm, /*waitSome=*/false));
		if (plan->hasProxyOps) {
		          if (!acquired) {
		            acquired = true;
		            NCCLCHECKGOTO(ncclStrongStreamAcquire(tasks->capturingGraph, &comm->sharedRes->hostStream), result, failure);
		          }
		          NCCLCHECKGOTO(ncclStrongStreamLaunchHost(tasks->capturingGraph, &comm->sharedRes->hostStream, hostStreamPlanCallback, plan), result, failure);
		        }
```

在** **`ncclLaunchKernelAfter_NoCuda()`** **中则是

```c++
ncclResult_t ncclLaunchKernelAfter_NoCuda(struct ncclComm* comm, struct ncclKernelPlan* plan) {
	if (!(plan->persistent || comm->persistentRefs != 0 || ncclCudaLaunchBlocking)) {
	  // 立即触发plan清理
	  NCCLCHECK(hostStreamPlanTask(comm, plan));
	} else {
	  // 延迟清理：将reclaimer加入callbackQueue
	  if (!plan->persistent && !plan->hasProxyOps) {
	    ncclIntruQueueMpscEnqueue(&comm->callbackQueue, &plan->reclaimer);
	  }
	}
}
```

最后一处相关的则是`ncclLaunchFinish` 内`ncclIntruQueueConstruct(&comm->planQueue);` ，这个API将plan队列重置为空，但没有销毁对象（plans），因为它们会通过 callbackQueue 回调队列返回给我们以便回收。

这里是宏观清理，整个 kernel plan 执行完成后的资源回收，一次清理一个 plan 中的所有 channels 的所有 ops。

### d. NCCL Proxy Cleanup：（communicator生命周期的全局resources）

> [!note]+ **Proxy core data structures：**
> ncclProxyState，ncclProxyOpsPool，ncclProxyProgressState，ncclProxyOp(这个包括三种状态，OpNone、OpReady、OpProgress对应0、1、2)。

> [!note]+ **Proxy core functions： **
> | **功能** | **目的** |
> | --- | --- |
> | `**ncclProxySaveOp()**` | 保存代理操作以供执行 |
> | `**ncclProxyStart()**` | 启动代理服务 |
> | `**ncclProxyInit()**` | 初始化代理状态 |
> | `**ncclProxyCreate()**` | 创建代理实例 |
> | `**ncclProxyConnect()**` | 连接到远程代理 |
> | `**ncclProxyStop()**` | 停止代理服务 |
> | `**ncclProxyDestroy()**` | 清理代理资源 |


> [!note]+ `static ncclResult_t SendProxyFree` 清理发端proxy资源（cudaStreamDestroy→cudaEventDestroy→ncclCudaFree→ncclCudaHostFree）
> 2

> [!note]+ `static ncclResult_t RecvroxyFree` 清理收端proxy资源（ncclP2pFreeShareableBuffer→ncclCudaFree）


> [!note]+ `ncclResult_t SendFree(struct ncclConnector* send)`，清理发端connector资源(cudaIpcCloseMemHandle→ncclShmClose(关闭shared mempry)→free) 


> [!note]+ `ncclResult_t RecvFree(struct ncclConnector* recv)` ，清理收端connector资源(cudaIpcCloseMemHandle→free)


> [!note]+ 问题
> 1. 有些API没有实现
> 
> | 在 src/psm/psm_proxy.h 中： | 在 src/proxy.cc 中： |
> | --- | --- |
> | psmProxyCallAsync(...)❌ | ncclProxyCallAsync(...)✅ |
> | psmProxyCallBlocking(...)❌ | ncclProxyCallBlocking(...)✅ |
> | psmPollProxyResponse(...)❌ | ncclPollProxyResponse(...) ✅ |
> | psmProxyClientGetFdBlocking(...)❌ | ncclProxyClientGetFdBlocking(...) ✅ |
> | psmProxyStop(...)❌ | ncclProxyStop(...) ✅ |
> | psmProxyDestroy(…)⭕️ | ncclProxyDestroy(…)⭕️ |
> | psmProxySaveOp(…) ⭕️ | ncclProxySaveOp(…)⭕️ |
> | psmProxyInit(…) ⭕️ | ncclProxyInit(…) ⭕️ |
> |   |   |
> |   |   |
> |   |   |
> |   |   |
> |   |   |
> |   |   |


> [!note]+ proxy debug infomations
> ```shell
> node201:709393:712147 [1] NCCL INFO New proxy send connection 96 from local rank 1, transport 2
> node201:709393:712147 [1] NCCL INFO proxyProgressAsync opId=0x7f0215c09cc0 op.type=1 op.reqBuff=0x7f01c409c740 op.respSize=16 done
> node201:709393:712006 [1] NCCL INFO ncclPollProxyResponse Received new opId=0x7f0215c09cc0
> node201:709393:712006 [1] NCCL INFO resp.opId=0x7f0215c09cc0 matches expected opId=0x7f0215c09cc0
> node201:709393:712147 [1] NCCL INFO Received and initiated operation=Init res=0
> node201:709393:712006 [1] NCCL INFO Connected to proxy localRank 1 -> connection 0x7f01c4008540
> node201:709393:712147 [1] NCCL INFO proxyProgressAsync opId=0x7f0215c09cc0 op.type=2 op.reqBuff=0x7f01c409dcb0 op.respSize=0 done
> node201:709393:712006 [1] NCCL INFO ncclPollProxyResponse Received new opId=0x7f0215c09cc0
> node201:709393:712006 [1] NCCL INFO resp.opId=0x7f0215c09cc0 matches expected opId=0x7f0215c09cc0
> node201:709393:712147 [1] NCCL INFO Received and initiated operation=SharedInit res=0有的还打印出了node201:709393:712147 [1] NCCL INFO Received and initiated operation=SharedInit res=0
> ...
> node201:709392:712151 [0] NCCL INFO New proxy recv connection 73 from local rank 0, transport 0
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=1 op.reqBuff=0x7fa4f400ca30 op.respSize=16 done
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Init res=0
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709392:712320 [0] NCCL INFO Connected to proxy localRank 0 -> connection 0x7fa4f4007850
> 
> node201:709393:712147 [1] NCCL INFO New proxy send connection 97 from local rank 1, transport 0
> node201:709393:712147 [1] NCCL INFO proxyProgressAsync opId=0x7efbdc007c20 op.type=1 op.reqBuff=0x7f01c400ca30 op.respSize=16 done
> node201:709393:712147 [1] NCCL INFO Received and initiated operation=Init res=0
> node201:709393:712321 [1] NCCL INFO ncclPollProxyResponse Received new opId=0x7efbdc007c20
> node201:709393:712321 [1] NCCL INFO resp.opId=0x7efbdc007c20 matches expected opId=0x7efbdc007c20
> node201:709393:712321 [1] NCCL INFO Connected to proxy localRank 1 -> connection 0x7f01c40085d0
> 
> node201:709394:712148 [2] NCCL INFO New proxy send connection 97 from local rank 2, transport 0
> node201:709394:712148 [2] NCCL INFO proxyProgressAsync opId=0x7f1f6c007c20 op.type=1 op.reqBuff=0x7f254c00ca30 op.respSize=16 done
> node201:709394:712148 [2] NCCL INFO Received and initiated operation=Init res=0
> node201:709394:712322 [2] NCCL INFO ncclPollProxyResponse Received new opId=0x7f1f6c007c20
> node201:709394:712322 [2] NCCL INFO resp.opId=0x7f1f6c007c20 matches expected opId=0x7f1f6c007c20
> node201:709394:712322 [2] NCCL INFO Connected to proxy localRank 2 -> connection 0x7f254c0085d0
> node201:709397:712138 [5] NCCL INFO New proxy send connection 97 from local rank 5, transport 0
> node201:709397:712138 [5] NCCL INFO proxyProgressAsync opId=0x7f9c24007c20 op.type=1 op.reqBuff=0x7fa20000ca30 op.respSize=16 done
> node201:709397:712138 [5] NCCL INFO Received and initiated operation=Init res=0
> node201:709397:712325 [5] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9c24007c20
> node201:709397:712325 [5] NCCL INFO resp.opId=0x7f9c24007c20 matches expected opId=0x7f9c24007c20
> node201:709397:712325 [5] NCCL INFO Connected to proxy localRank 5 -> connection 0x7fa2000085d0
> node201:709396:712145 [4] NCCL INFO New proxy send connection 97 from local rank 4, transport 0
> node201:709396:712145 [4] NCCL INFO proxyProgressAsync opId=0x7fdd74007c20 op.type=1 op.reqBuff=0x7fe35800ca30 op.respSize=16 done
> node201:709396:712145 [4] NCCL INFO Received and initiated operation=Init res=0
> node201:709396:712324 [4] NCCL INFO ncclPollProxyResponse Received new opId=0x7fdd74007c20
> node201:709396:712324 [4] NCCL INFO resp.opId=0x7fdd74007c20 matches expected opId=0x7fdd74007c20
> node201:709396:712324 [4] NCCL INFO Connected to proxy localRank 4 -> connection 0x7fe3580085d0
> node201:709398:712141 [6] NCCL INFO New proxy send connection 97 from local rank 6, transport 0
> node201:709398:712141 [6] NCCL INFO proxyProgressAsync opId=0x7fcd64007c20 op.type=1 op.reqBuff=0x7fd35000ca30 op.respSize=16 done
> node201:709398:712141 [6] NCCL INFO Received and initiated operation=Init res=0
> node201:709398:712326 [6] NCCL INFO ncclPollProxyResponse Received new opId=0x7fcd64007c20
> node201:709398:712326 [6] NCCL INFO resp.opId=0x7fcd64007c20 matches expected opId=0x7fcd64007c20
> node201:709398:712326 [6] NCCL INFO Connected to proxy localRank 6 -> connection 0x7fd3500085d0
> node201:709395:712137 [3] NCCL INFO New proxy send connection 97 from local rank 3, transport 0
> node201:709395:712137 [3] NCCL INFO proxyProgressAsync opId=0x7fe250007c20 op.type=1 op.reqBuff=0x7fe83c00ca30 op.respSize=16 done
> node201:709395:712137 [3] NCCL INFO Received and initiated operation=Init res=0
> node201:709395:712323 [3] NCCL INFO ncclPollProxyResponse Received new opId=0x7fe250007c20
> node201:709395:712323 [3] NCCL INFO resp.opId=0x7fe250007c20 matches expected opId=0x7fe250007c20
> node201:709395:712323 [3] NCCL INFO Connected to proxy localRank 3 -> connection 0x7fe83c0085d0
> node201:709399:712139 [7] NCCL INFO New proxy send connection 73 from local rank 7, transport 0
> node201:709399:712139 [7] NCCL INFO proxyProgressAsync opId=0x7f0ae0007c20 op.type=1 op.reqBuff=0x7f10bc00ca30 op.respSize=16 done
> node201:709399:712139 [7] NCCL INFO Received and initiated operation=Init res=0
> node201:709399:712327 [7] NCCL INFO ncclPollProxyResponse Received new opId=0x7f0ae0007c20
> node201:709399:712327 [7] NCCL INFO resp.opId=0x7f0ae0007c20 matches expected opId=0x7f0ae0007c20
> node201:709399:712327 [7] NCCL INFO Connected to proxy localRank 7 -> connection 0x7f10bc007850
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=3 op.reqBuff=0x7fa4f407b370 op.respSize=80 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Setup res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709399:712139 [7] NCCL INFO proxyProgressAsync opId=0x7f0ae0007c20 op.type=3 op.reqBuff=(nil) op.respSize=240 done
> node201:709399:712327 [7] NCCL INFO ncclPollProxyResponse Received new opId=0x7f0ae0007c20
> node201:709399:712139 [7] NCCL INFO Received and initiated operation=Setup res=0
> node201:709399:712327 [7] NCCL INFO resp.opId=0x7f0ae0007c20 matches expected opId=0x7f0ae0007c20
> node201:709396:712145 [4] NCCL INFO proxyProgressAsync opId=0x7fdd74007c20 op.type=3 op.reqBuff=(nil) op.respSize=240 done
> node201:709396:712324 [4] NCCL INFO ncclPollProxyResponse Received new opId=0x7fdd74007c20
> node201:709396:712145 [4] NCCL INFO Received and initiated operation=Setup res=0
> node201:709396:712324 [4] NCCL INFO resp.opId=0x7fdd74007c20 matches expected opId=0x7fdd74007c20
> node201:709397:712138 [5] NCCL INFO proxyProgressAsync opId=0x7f9c24007c20 op.type=3 op.reqBuff=(nil) op.respSize=240 done
> node201:709397:712325 [5] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9c24007c20
> node201:709397:712138 [5] NCCL INFO Received and initiated operation=Setup res=0
> node201:709397:712325 [5] NCCL INFO resp.opId=0x7f9c24007c20 matches expected opId=0x7f9c24007c20
> node201:709399:712327 [7] NCCL INFO ProxyCall UDS comm 0x55f0ee791ec0 rank 7 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 0x7f0ae9ffebe0 opId 0xc38d1761f4ed51d7
> node201:709393:712147 [1] NCCL INFO proxyProgressAsync opId=0x7efbdc007c20 op.type=3 op.reqBuff=(nil) op.respSize=240 done
> node201:709393:712321 [1] NCCL INFO ncclPollProxyResponse Received new opId=0x7efbdc007c20
> node201:709393:712147 [1] NCCL INFO Received and initiated operation=Setup res=0
> node201:709393:712321 [1] NCCL INFO resp.opId=0x7efbdc007c20 matches expected opId=0x7efbdc007c20
> node201:709394:712148 [2] NCCL INFO proxyProgressAsync opId=0x7f1f6c007c20 op.type=3 op.reqBuff=(nil) op.respSize=240 done
> node201:709394:712322 [2] NCCL INFO ncclPollProxyResponse Received new opId=0x7f1f6c007c20
> node201:709394:712148 [2] NCCL INFO Received and initiated operation=Setup res=0
> node201:709394:712322 [2] NCCL INFO resp.opId=0x7f1f6c007c20 matches expected opId=0x7f1f6c007c20
> node201:709392:712151 [0] NCCL INFO New proxy recv connection 74 from local rank 0, transport 0
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=1 op.reqBuff=0x7fa4f407b370 op.respSize=16 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Init res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709392:712320 [0] NCCL INFO Connected to proxy localRank 0 -> connection 0x7fa4f40078e0
> node201:709392:712152 [0] NCCL INFO proxyUDSRecvReq::ncclProxyMsgGetFd rank 7 opId 0xc38d1761f4ed51d7 handle=0x7fa4f407d330
> node201:709392:712152 [0] NCCL INFO UDS proxyGetFd received handle 0x7fa4f407d330 peer 7 opId c38d1761f4ed51d7
> node201:709398:712141 [6] NCCL INFO proxyProgressAsync opId=0x7fcd64007c20 op.type=3 op.reqBuff=(nil) op.respSize=240 done
> node201:709398:712326 [6] NCCL INFO ncclPollProxyResponse Received new opId=0x7fcd64007c20
> node201:709398:712141 [6] NCCL INFO Received and initiated operation=Setup res=0
> node201:709398:712326 [6] NCCL INFO resp.opId=0x7fcd64007c20 matches expected opId=0x7fcd64007c20
> node201:709395:712137 [3] NCCL INFO proxyProgressAsync opId=0x7fe250007c20 op.type=3 op.reqBuff=(nil) op.respSize=240 done
> node201:709395:712323 [3] NCCL INFO ncclPollProxyResponse Received new opId=0x7fe250007c20
> node201:709395:712137 [3] NCCL INFO Received and initiated operation=Setup res=0
> node201:709395:712323 [3] NCCL INFO resp.opId=0x7fe250007c20 matches expected opId=0x7fe250007c20
> node201:709399:712327 [7] NCCL INFO ProxyCall UDS comm 0x55f0ee791ec0 rank 7 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 157 opId 0xc38d1761f4ed51d7 - DONE
> node201:709399:712327 [7] NCCL INFO UDS: ClientGetFd handle 0x7fa4f407d330 tpRank 0 returned fd 157
> node201:709399:712139 [7] NCCL INFO proxyProgressAsync opId=0x7f0ae0007c20 op.type=4 op.reqBuff=0x7f10bc089ae0 op.respSize=0 done
> node201:709399:712139 [7] NCCL INFO Received and initiated operation=Connect res=0
> node201:709399:712327 [7] NCCL INFO ncclPollProxyResponse Received new opId=0x7f0ae0007c20
> node201:709399:712327 [7] NCCL INFO resp.opId=0x7f0ae0007c20 matches expected opId=0x7f0ae0007c20
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=3 op.reqBuff=0x7fa4f407ed70 op.respSize=80 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Setup res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709398:712326 [6] NCCL INFO ProxyCall UDS comm 0x56470487fa70 rank 6 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 0x7fcd6dffebe0 opId 0xa21d501bb3b45da8
> node201:709392:712151 [0] NCCL INFO New proxy recv connection 75 from local rank 0, transport 0
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=1 op.reqBuff=0x7fa4f407ed70 op.respSize=16 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Init res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709392:712320 [0] NCCL INFO Connected to proxy localRank 0 -> connection 0x7fa4f4007970
> node201:709392:712152 [0] NCCL INFO proxyUDSRecvReq::ncclProxyMsgGetFd rank 6 opId 0xa21d501bb3b45da8 handle=0x7fa4f407ed90
> node201:709392:712152 [0] NCCL INFO UDS proxyGetFd received handle 0x7fa4f407ed90 peer 6 opId a21d501bb3b45da8
> node201:709397:712325 [5] NCCL INFO ProxyCall UDS comm 0x556d5e45ddb0 rank 5 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 0x7f9c2dffebe0 opId 0x40f06cb450b4d0c
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=3 op.reqBuff=0x7fa4f4080a50 op.respSize=80 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Setup res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO New proxy recv connection 76 from local rank 0, transport 0
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=1 op.reqBuff=0x7fa4f4080a50 op.respSize=16 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Init res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709392:712320 [0] NCCL INFO Connected to proxy localRank 0 -> connection 0x7fa4f4007a00
> 
> node201:709398:712326 [6] NCCL INFO ProxyCall UDS comm 0x56470487fa70 rank 6 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 157 opId 0xa21d501bb3b45da8 - DONE
> node201:709398:712326 [6] NCCL INFO UDS: ClientGetFd handle 0x7fa4f407ed90 tpRank 0 returned fd 157
> node201:709392:712152 [0] NCCL INFO proxyUDSRecvReq::ncclProxyMsgGetFd rank 5 opId 0x40f06cb450b4d0c handle=0x7fa4f4080a70
> node201:709392:712152 [0] NCCL INFO UDS proxyGetFd received handle 0x7fa4f4080a70 peer 5 opId 40f06cb450b4d0c
> node201:709398:712141 [6] NCCL INFO proxyProgressAsync opId=0x7fcd64007c20 op.type=4 op.reqBuff=0x7fd3500af820 op.respSize=0 done
> node201:709398:712141 [6] NCCL INFO Received and initiated operation=Connect res=0
> node201:709398:712326 [6] NCCL INFO ncclPollProxyResponse Received new opId=0x7fcd64007c20
> node201:709398:712326 [6] NCCL INFO resp.opId=0x7fcd64007c20 matches expected opId=0x7fcd64007c20
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=3 op.reqBuff=0x7fa4f4082730 op.respSize=80 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Setup res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709396:712324 [4] NCCL INFO ProxyCall UDS comm 0x564946ccbfb0 rank 4 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 0x7fdd7dffebe0 opId 0x9666afda57f1549e
> node201:709392:712151 [0] NCCL INFO New proxy recv connection 77 from local rank 0, transport 0
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=1 op.reqBuff=0x7fa4f4082730 op.respSize=16 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Init res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709392:712320 [0] NCCL INFO Connected to proxy localRank 0 -> connection 0x7fa4f4007a90
> node201:709392:712152 [0] NCCL INFO proxyUDSRecvReq::ncclProxyMsgGetFd rank 4 opId 0x9666afda57f1549e handle=0x7fa4f4082750
> node201:709392:712152 [0] NCCL INFO UDS proxyGetFd received handle 0x7fa4f4082750 peer 4 opId 9666afda57f1549e
> node201:709397:712325 [5] NCCL INFO ProxyCall UDS comm 0x556d5e45ddb0 rank 5 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 157 opId 0x40f06cb450b4d0c - DONE
> node201:709397:712325 [5] NCCL INFO UDS: ClientGetFd handle 0x7fa4f4080a70 tpRank 0 returned fd 157
> node201:709396:712324 [4] NCCL INFO ProxyCall UDS comm 0x564946ccbfb0 rank 4 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 157 opId 0x9666afda57f1549e - DONE
> node201:709396:712324 [4] NCCL INFO UDS: ClientGetFd handle 0x7fa4f4082750 tpRank 0 returned fd 157
> node201:709396:712145 [4] NCCL INFO proxyProgressAsync opId=0x7fdd74007c20 op.type=4 op.reqBuff=0x7fe3580af820 op.respSize=0 done
> node201:709396:712145 [4] NCCL INFO Received and initiated operation=Connect res=0
> node201:709396:712324 [4] NCCL INFO ncclPollProxyResponse Received new opId=0x7fdd74007c20
> node201:709396:712324 [4] NCCL INFO resp.opId=0x7fdd74007c20 matches expected opId=0x7fdd74007c20
> node201:709397:712138 [5] NCCL INFO proxyProgressAsync opId=0x7f9c24007c20 op.type=4 op.reqBuff=0x7fa2000af820 op.respSize=0 done
> node201:709397:712138 [5] NCCL INFO Received and initiated operation=Connect res=0
> node201:709397:712325 [5] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9c24007c20
> node201:709397:712325 [5] NCCL INFO resp.opId=0x7f9c24007c20 matches expected opId=0x7f9c24007c20
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=3 op.reqBuff=0x7fa4f4084410 op.respSize=80 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Setup res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709395:712323 [3] NCCL INFO ProxyCall UDS comm 0x55e0e4bdc1e0 rank 3 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 0x7fe259ffebe0 opId 0x72d942102eb468e
> node201:709392:712152 [0] NCCL INFO proxyUDSRecvReq::ncclProxyMsgGetFd rank 3 opId 0x72d942102eb468e handle=0x7fa4f4084430
> node201:709392:712152 [0] NCCL INFO UDS proxyGetFd received handle 0x7fa4f4084430 peer 3 opId 72d942102eb468e
> node201:709392:712151 [0] NCCL INFO New proxy recv connection 78 from local rank 0, transport 0
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=1 op.reqBuff=0x7fa4f4084410 op.respSize=16 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Init res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709392:712320 [0] NCCL INFO Connected to proxy localRank 0 -> connection 0x7fa4f4007b20
> node201:709395:712323 [3] NCCL INFO ProxyCall UDS comm 0x55e0e4bdc1e0 rank 3 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 157 opId 0x72d942102eb468e - DONE
> node201:709395:712323 [3] NCCL INFO UDS: ClientGetFd handle 0x7fa4f4084430 tpRank 0 returned fd 157
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=3 op.reqBuff=0x7fa4f40860f0 op.respSize=80 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Setup res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO New proxy recv connection 79 from local rank 0, transport 0
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=1 op.reqBuff=0x7fa4f40860f0 op.respSize=16 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709394:712322 [2] NCCL INFO ProxyCall UDS comm 0x562af065c1b0 rank 2 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 0x7f1f75ffebe0 opId 0xaecc8df2a08df09a
> node201:709392:712320 [0] NCCL INFO Connected to proxy localRank 0 -> connection 0x7fa4f4007bb0
> node201:709392:712152 [0] NCCL INFO proxyUDSRecvReq::ncclProxyMsgGetFd rank 2 opId 0xaecc8df2a08df09a handle=0x7fa4f4086110
> node201:709392:712152 [0] NCCL INFO UDS proxyGetFd received handle 0x7fa4f4086110 peer 2 opId aecc8df2a08df09a
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Init res=0
> node201:709392:712151 [0] NCCL INFO proxyProgressAsync opId=0x7f9ea0007c20 op.type=3 op.reqBuff=0x7fa4f4087dd0 op.respSize=80 done
> node201:709392:712320 [0] NCCL INFO ncclPollProxyResponse Received new opId=0x7f9ea0007c20
> node201:709392:712151 [0] NCCL INFO Received and initiated operation=Setup res=0
> node201:709392:712320 [0] NCCL INFO resp.opId=0x7f9ea0007c20 matches expected opId=0x7f9ea0007c20
> node201:709393:712321 [1] NCCL INFO ProxyCall UDS comm 0x557902a6c560 rank 1 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 0x7efbe5ffebe0 opId 0x7098875de36c2be
> node201:709394:712322 [2] NCCL INFO ProxyCall UDS comm 0x562af065c1b0 rank 2 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 157 opId 0xaecc8df2a08df09a - DONE
> node201:709394:712322 [2] NCCL INFO UDS: ClientGetFd handle 0x7fa4f4086110 tpRank 0 returned fd 157
> node201:709392:712152 [0] NCCL INFO proxyUDSRecvReq::ncclProxyMsgGetFd rank 1 opId 0x7098875de36c2be handle=0x7fa4f4087df0
> node201:709392:712152 [0] NCCL INFO UDS proxyGetFd received handle 0x7fa4f4087df0 peer 1 opId 7098875de36c2be
> node201:709395:712137 [3] NCCL INFO proxyProgressAsync opId=0x7fe250007c20 op.type=4 op.reqBuff=0x7fe83c0af820 op.respSize=0 done
> node201:709395:712137 [3] NCCL INFO Received and initiated operation=Connect res=0
> node201:709395:712323 [3] NCCL INFO ncclPollProxyResponse Received new opId=0x7fe250007c20
> node201:709395:712323 [3] NCCL INFO resp.opId=0x7fe250007c20 matches expected opId=0x7fe250007c20
> node201:709394:712148 [2] NCCL INFO proxyProgressAsync opId=0x7f1f6c007c20 op.type=4 op.reqBuff=0x7f254c0af820 op.respSize=0 done
> node201:709394:712148 [2] NCCL INFO Received and initiated operation=Connect res=0
> node201:709394:712322 [2] NCCL INFO ncclPollProxyResponse Received new opId=0x7f1f6c007c20
> node201:709394:712322 [2] NCCL INFO resp.opId=0x7f1f6c007c20 matches expected opId=0x7f1f6c007c20
> node201:709393:712321 [1] NCCL INFO ProxyCall UDS comm 0x557902a6c560 rank 1 tpRank 0(64b7c3a0585db18e) reqSize 8 respSize 0 respFd 157 opId 0x7098875de36c2be - DONE
> node201:709393:712321 [1] NCCL INFO UDS: ClientGetFd handle 0x7fa4f4087df0 tpRank 0 returned fd 157
> node201:709393:712147 [1] NCCL INFO proxyProgressAsync opId=0x7efbdc007c20 op.type=4 op.reqBuff=0x7f01c40af820 op.respSize=0 done
> node201:709393:712147 [1] NCCL INFO Received and initiated operation=Connect res=0
> node201:709393:712321 [1] NCCL INFO ncclPollProxyResponse Received new opId=0x7efbdc007c20
> node201:709393:712321 [1] NCCL INFO resp.opId=0x7efbdc007c20 matches expected opId=0x7efbdc007c20
> ```


**根本问题：**`**psmP2pSendProxySetup()**`** 这句** `cpp memcpy(respBuff, proxyInfo, sizeof(struct p2pShmProxyInfo)); ` 把 **整个** `p2pShmProxyInfo` 复制到了响应缓冲区，随后在 **另一端的 **`**psmP2p{Send|Recv}Connect()**` 里又把这块内存 `memcpy()` 回本进程 （见你在 `psmP2pRecvConnect()` 里的那几行）： `cpp proxyInfo = (struct p2pShmProxyInfo*)recv->proxyConn.connection->transportResources; /* 这里把 desc/ptr 等字段重新写回 proxyInfo */ proxyInfo->shm = resources->shm; proxyInfo->devShm = resources->devShm; ... ` 结果是： 1. **你在 *****Setup***** 阶段新建的 **`**proxyInfo->stream**`** 句柄被覆盖** ——覆盖成了对端进程地址空间里的一个无意义整数。 后面进入 `psmP2pRecvProxyProgress()` 时，读出的 `resources->stream` 不是 0 (legacy stream)，就是一个失效指针；第一批 `cudaMemcpyAsync()` 落到默认 stream → 再次隐式同步 → hang。 2. 同理，`events[]` 指针如果也放在同一个结构体里，回拷时同样被破坏， 造成 `cudaEventQuery()` 访问非法地址或一直 `NotReady`。 --- ## 为什么 SHM‑transport 不会出问题？ `shmSend/RecvProxySetup()` **只拷贝可共享字段**： `cpp memcpy(&info->desc, &proxyInfo->desc, sizeof(ncclShmIpcDesc_t)); ` 它**没有**把含有本地句柄的 `shmProxyInfo` 整个丢给对端。 --- ## 修复策略 ### ① 划分“可共享”与“本地”字段 `cpp struct p2pShmProxyShare { ncclShmIpcDesc_t desc; /* 只含对端需要 attach 的东西 */ }; /* 本地进程专用 */ struct p2pShmProxyInfo { cudaStream_t stream; cudaEvent_t events[PSM_STEPS]; struct ncclSendMem* shm; struct ncclSendMem* devShm; ncclShmIpcDesc_t desc; char* recvFifo; }; ` ### ② *Setup* 阶段 `cpp struct p2pShmProxyInfo* proxyInfo; NCCLCHECK(ncclCalloc(&proxyInfo, 1)); CUDACHECK(cudaStreamCreateWithFlags(&proxyInfo->stream, cudaStreamNonBlocking)); for (int i=0; i<PSM_STEPS; ++i) CUDACHECK(cudaEventCreateWithFlags(proxyInfo->events+i, cudaEventDisableTiming)); /* 只发 shareable 字段 */ struct p2pShmProxyShare share = { proxyInfo->desc }; memcpy(respBuff, &share, sizeof(share)); connection->transportResources = proxyInfo; ` ### ③ *Connect* 阶段（另一端） `cpp /* attach 共享段后，本地再建自己的 stream / events */ struct p2pShmProxyInfo* proxyInfo; NCCLCHECK(ncclCalloc(&proxyInfo, 1)); CUDACHECK(cudaStreamCreateWithFlags(&proxyInfo->stream, cudaStreamNonBlocking)); for (int i=0; i<PSM_STEPS; ++i) CUDACHECK(cudaEventCreateWithFlags(proxyInfo->events+i, cudaEventDisableTiming)); proxyInfo->desc = share->desc; NCCLCHECK(ncclShmImportShareableBuffer(..., &proxyInfo->desc, ...)); ... recv->proxyConn.connection->transportResources = proxyInfo; ` **绝不能再把 **`**proxyInfo**`** 整体 **`**memcpy()**`** 给对端**。 ### ④ 进度循环里加保险 `cpp if (resources->stream == 0) CUDACHECK(cudaStreamCreateWithFlags(&resources->stream, cudaStreamNonBlocking)); ` --- ## 其他检查点 | 检查 | 目的 | |------|------| | `resources->events[buffSlot]` 在本地创建后 **只在同一个进程使用** | 防止事件句柄跨进程失效 | | `sizeof(p2pShmProxyShare)` 是否 <= `respSize` | 避免大小不匹配 | | **所有** Pass‑SM / cuMem 分支都分配 `p2pShmProxyInfo` 并创建 `stream` | 保证不会走到 `connection->transportResources = p2pBuff->directPtr` 这条无 `stream` 路径 | 修完后，再跑原来的 8 GPU × 4 GB All‑to‑All，`recvTail` 应当继续向前推进，`canSend=NO` 的打印会消失，整条链路不会再在 `step==320` 处卡死。 ::contentReference[oaicite:0]{index=0}








