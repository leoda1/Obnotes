# 1. 前言
nccl在上周的更新当中除了未来doca refactor的transport层之外，还有一个重头戏就是新增的无核（nccl称呼这个为Zero CTA，或者nccl也叫这是用CopyEngine完成）的四个cc操作（alltoall, allgather, gather,scatter）。这里的最重要的就是它是用的是symmetric内存去做的，其实比最重要的更重要的是它为什么用symmetric，最后会说这个。早在之前的nccltest内就可以用 `-R 1`来用非对称内存的registration mode，但是现在只支持机内的这四个CE实现的cc操作可以用 `-R 2`简单玩一下。
# 2. ceAlltoall的实现
在group.cc内的doLaunches内可看到现在是否走kernel已经从根源上直接划分了。
```cpp
if (plan->isCeColl) {
	NCCLCHECKGOTO(ncclLaunchCeColl(comm, plan), result, failure);
} else {
	NCCLCHECKGOTO(ncclLaunchKernel(comm, plan), result, failure);
}
```
进入正题：在collectives.cc内可以看到，新的alltoall一样使用 ncclEnqueueCheck 把任务enqueue。
```cpp
NCCL_API(ncclResult_t, ncclAlltoAll, const void* sendbuff, void* recvbuff, size_t count,
    ncclDataType_t datatype, ncclComm* comm, cudaStream_t stream);
ncclResult_t ncclAlltoAll(const void* sendbuff, void* recvbuff, size_t count,
    ncclDataType_t datatype, ncclComm* comm, cudaStream_t stream) {
  NVTX3_FUNC_WITH_PARAMS(AlltoAll, NcclNvtxParamsAlltoAll,
    NVTX3_PAYLOAD(comm ? comm->commHash : 0, count * ncclTypeSize(datatype)));

  struct ncclInfo info = { ncclFuncAlltoAll, "AlltoAll",
    sendbuff, recvbuff, count, datatype, ncclSum, 0, comm, stream, /* Args */
    ALLTOALL_CHUNKSTEPS, ALLTOALL_SLICESTEPS };
  return ncclEnqueueCheck(&info);
}
```
在enqueue.cc的taskAppend内可以看到：
```cpp
bool ceImplemented = ncclCeImplemented(info->coll, info->op, info->datatype);
// Append CE collective task if CE is supported and requested by user
if (comm->symmetricSupport && comm->nNodes == 1 && sendWin && recvWin && (sendWin->winFlags & recvWin->winFlags & NCCL_WIN_COLL_SYMMETRIC) && comm->config.CTAPolicy == NCCL_CTA_POLICY_ZERO && ceImplemented) {
	NCCLCHECK(ceCollTaskAppend(comm, info, sendWin, recvWin, opDev));
}
// Append kernel-based collective，
else {...}
```
这里的ceImplemented定义为cuda大于等于12.5，并且是新增的支持CE的四个CC通信之一就是true。不同就在于这里的p2p任务现在分成了两种ceCollTaskAppend和p2pTaskAppend，然后不支持CE的传统CC走collTaskAppend。
任务加到planner之后，nccl的标准5步启动kernel的过程中的LaunchPrepare内可以看到现在planner内的有collSymTaskQueue和collCeTaskQueue。
在group.cc内的doLaunches内现在可以看到，之前走kernel的方式变成了`ncclLaunchCeColl` 
```cpp
if (plan != nullptr) {
	comm->planner.unlaunchedPlansHead = plan->next;
	CUDACHECKGOTO(cudaSetDevice(comm->cudaDev), result, failure);
	NCCLCHECKGOTO(ncclLaunchKernelBefore_NoUncapturedCuda(comm, plan), result, failure);
	if (plan->isCeColl) {
		NCCLCHECKGOTO(ncclLaunchCeColl(comm, plan), result, failure);
	} else {
		NCCLCHECKGOTO(ncclLaunchKernel(comm, plan), result, failure);
	}
}
```
那么在ncclLaunchCeColl内对新的ncclAlltoall做了什么？我们接着看新增的src/ce_coll.cc（代码量不大，单拎alltoall来说，因为moe训练的话alltoall很重要）。
ncclLaunchCeColl会根据plan内的ceCollArgs（在ncclLaunchPrepare内准备好了需要的地址，数量，数据类型等）的func来看当前是ncclCeAlltoAll还是其他新加的。
```cpp
typedef enum {
  ...
  ncclFuncAlltoAll = 8,
  ncclFuncScatter = 9,
  ncclFuncGather = 10,
  ncclNumFuncs = 11
} ncclFunc_t;
```
这省略了一些case。。不全说
```cpp
ncclResult_t ncclLaunchCeColl(struct ncclComm* comm, struct ncclKernelPlan* plan) {
	...
  switch (args->func) {
	  ...
    case ncclFuncAlltoAll:
      NCCLCHECKGOTO(ncclCeAlltoAll(comm, args, stream), ret, fail);
      break;
    ...
}
```
在 `ncclCeAlltoAll` 内抽象的步骤大概就是5步：初始化batch操作的参数结构->同步所有rank（五颗星）-> 获取远程 rank 的内存地址指针去直接内存访问（DMA）->执行批处理操作 -> 第二次同步所有rank -> 释放内存。
```cpp
ncclResult_t ncclCeAlltoAll(struct ncclComm* comm, struct ncclCeCollArgs* args, cudaStream_t stream) {
	...
  struct ncclCeBatchOpsParams batchOpsParams = {};
  1. NCCLCHECKGOTO(ncclCeInitBatchOpsParams(&batchOpsParams, comm->nRanks * comm->nRanks), ret, fail);
  
  2. NCCLCHECKGOTO(ncclMemOpSync(comm, stream), ret, fail);

  for (int r = 0; r < comm->nRanks; r++) {
    int dstRank = (comm->rank + r) % comm->nRanks;
    uint8_t* srcPtr = mySendBuff + dstRank * chunkBytes;
    uint8_t* dstPtr = myRecvBuff + comm->rank * chunkBytes;
    
    if (dstRank == comm->rank) {
      // Local copy for own data
      ...
    } else {
      // Remote copy to other ranks: send to rank dstRank's receive buffer at position comm->rank
      offset = dstPtr - (uint8_t*)args->recvWin->userPtr;
      3. NCCLCHECKGOTO(ncclDevrGetLsaRankPtr(comm, args->recvWin, offset, dstRank, &peerRecvBuff), ret, fail);
      batchOpsParams.srcs[batchOpsParams.numOps] = (void*)srcPtr;
      batchOpsParams.dsts[batchOpsParams.numOps] = (void*)peerRecvBuff;
      batchOpsParams.sizes[batchOpsParams.numOps] = chunkBytes;
      batchOpsParams.numOps++;
    }
  }

  // Check if we need to perform intra-batch synchronization
  batchOpsParams.intraBatchSync = (batchOpsParams.numOps > comm->ceColl.intraBatchSyncFreq && chunkBytes*batchOpsParams.numOps >= comm->ceColl.intraBatchSyncMsgThreshold);

  // Launch the batch operations
  4. NCCLCHECKGOTO(ncclCeLaunchBatchOps(comm, &batchOpsParams, stream), ret, fail);

  // Ensure all transfers are complete across all ranks
  2. NCCLCHECKGOTO(ncclMemOpSync(comm, stream), ret, fail);
  
  3. ncclCeFreeBatchOpsParams(&batchOpsParams);
  ...
}
```

## step1: ncclCeInitBatchOpsParams(&batchOpsParams, comm->nRanks * comm->nRanks)
 一步带过，这里初始化了一个结构类型是 `ncclCeBatchOpsParams` 的batchOpsParams。`batchOpsParams` 会在后面存真正发送用到的dst，src地址，size大小和opCount。
## step2: ncclMemOpSync(comm, stream)
这一步主要是让所有rank在开始数据传输之前都处于就绪状态。细看的话，早在group.cc内的 `groupLaunch` 阶段内发现是对称内存的话就会走 `ncclCommGroupRegisterSymmetric` 注册，`ncclCommGroupRegisterSymmetric` 内有专门对现在的ce操作的 `ncclCeInit`。

而 `ncclMemOpSync` 主要就是同步两个状态，分别是ready和complete。在 `ncclCeInit` 内：
```cpp
ncclResult_t ncclCeInit(struct ncclComm* comm) {
  ncclResult_t ret = ncclSuccess;

  uint8_t* ceDevBase;
  1. size_t ceDevBaseSize = alignUp(comm->nRanks*sizeof(uint32_t), 16) * 2;
  ncclWindow_vidmem* ceWinDev;
  ncclWindow_vidmem* ceWinDevHost;

  // Ensure symmetric memory runtime is initialized
  2. NCCLCHECKGOTO(ncclDevrInitOnce(comm), ret, fail);
  // Allocate and register memory for the symmetric memory
  3. NCCLCHECKGOTO(ncclMemAlloc((void**)&ceDevBase, ceDevBaseSize), ret, fail);
  4. NCCLCHECKGOTO(ncclDevrWindowRegisterInGroup(comm, ceDevBase, ceDevBaseSize, NCCL_WIN_COLL_SYMMETRIC, &ceWinDev), ret, fail);
  5. NCCLCHECKGOTO(ncclShadowPoolToHost(&comm->devrState.shadows, ceWinDev, &ceWinDevHost), ret, fail);
  // Get the ncclDevrWindow from the winHost field
  comm->ceColl.ceSyncWin = (struct ncclDevrWindow*)ceWinDevHost->winHost;

  6. comm->ceColl.baseUCSymReadyOffset = 0;
  comm->ceColl.baseUCSymComplOffset = alignUp(comm->nRanks*sizeof(uint32_t), 16);
  comm->ceColl.baseUCSymReadyPtr = (uint8_t*)comm->ceColl.ceSyncWin->userPtr + comm->ceColl.baseUCSymReadyOffset;
  comm->ceColl.baseUCSymComplPtr = (uint8_t*)comm->ceColl.ceSyncWin->userPtr + comm->ceColl.baseUCSymComplOffset;
  comm->ceColl.ceSeqNum = 0;
  comm->ceColl.useCompletePtr = false;
  comm->ceColl.intraBatchSyncFreq = CE_COLL_INTRA_BATCH_SYNC_FREQ;
  comm->ceColl.intraBatchSyncMsgThreshold = CE_COLL_INTRA_BATCH_SYNC_MSG_THRESHOLD;
}

```
1. 给每个rank开出来一个uint32_t，对齐到16字节乘2，放ready和complete这俩数组。
	![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250926191944951.png)
2. symmetric memory runtime初始化检查
3. 用的 `ncclMemAlloc` 分配GPU内存
4. `ncclDevrWindowRegisterInGroup` 注册对称内存
5. `ncclShadowPoolToHost` 把开出来并注册好的对称内存 `ceDevBase` 映射给host端(ceWinDevHost)，并且让comm->ceColl.ceSyncWin指向这个 `ceWinDevHost` 内的 `winHost`，再后面做同步的时候这个地址就是基址。
6. 开始往comm->ceColl结构内填写要的字段，主要是 `baseUCSymReadyPtr` 和 `baseUCSymComplPtr` ，以及这里 `useCompletePtr` 用来表示在这两个阶段之间切换。

在 `ncclMemOpSync` 内，假如是机间没有cudagraph的场景:
```cpp
ncclResult_t ncclMemOpSync(struct ncclComm* comm, cudaStream_t stream) {
  // Get pointers to the ready and complete synchronization arrays
  uint32_t* readyPtrs = (uint32_t*)comm->ceColl.baseUCSymReadyPtr;
  uint32_t* completePtrs = (uint32_t*)comm->ceColl.baseUCSymComplPtr;
  
  // Allocate enough slots for all possible ops
  1. size_t batchSize = (comm->nvlsSupport ? NCCL_CE_SYNC_OPS_PER_RANK_MC : NCCL_CE_SYNC_OPS_PER_RANK_UC) * comm->nRanks;
  size_t opIdx = 0;

  // Prepare batch memory operations for synchronization
  CUstreamBatchMemOpParams* batchParams = nullptr;
  NCCLCHECKGOTO(ncclCalloc(&batchParams, batchSize), ret, fail);

  if (comm->nvlsSupport) {
    2. NCCLCHECKGOTO(ncclPrepMCSync(comm, comm->ceColl.useCompletePtr, batchParams, &opIdx, stream), ret, fail);
  } else {
    3. NCCLCHECKGOTO(ncclPrepUCSync(comm, comm->ceColl.useCompletePtr, batchParams, &opIdx), ret, fail);
  }

  // For CUDA graph capture, add reset operation
  if (ncclCudaGraphValid(comm->planner.capturingGraph)) {
    ...
  }
  // Execute all memory operations in a single batch
  4. CUCHECKGOTO(cuStreamBatchMemOp(stream, opIdx, batchParams, 0), ret, fail);
  // Toggle the flag for next call
  5. comm->ceColl.useCompletePtr = !comm->ceColl.useCompletePtr;
```
1. 先根据是否支持nvls来判断接下来会走MC(Multi-cast)还是UC(Uni-cast)；这里的batchSize是也是一个槽，MC就是2倍comm->nranks；UC就是3倍comm->nranks;
2. `ncclPrepMCSync` 通过组播同时下发多个write/wait。
3. `ncclPrepUCSync` 单播，一个一个发。
4. `cuStreamBatchMemOp` 一次性提交所有写或者等待操作，CUDA会去执行这些操作。opIdx必须小于256。CUDA看不见 `batchParams` 上的同步顺序。
5. 切换当前 `useCompletePtr` 状态。

`ncclPrepMCSync` 内步骤是从host侧用cudaMemcpyAsync（H2D）把同步信号从cpu侧搬到multicast object上。


`ncclPrepUCSync` 内对写和等待两种操作做了什么？
```cpp
ncclResult_t ncclPrepUCSync(struct ncclComm* comm, bool isComplete,
                               CUstreamBatchMemOpParams* batchParams,
                               size_t* opIdx) {
  ncclResult_t ret = ncclSuccess;
  uint32_t* readyPtrs    = (uint32_t*)comm->ceColl.baseUCSymReadyPtr;
  uint32_t* completePtrs = (uint32_t*)comm->ceColl.baseUCSymComplPtr;

  bool capturing = ncclCudaGraphValid(comm->planner.capturingGraph);
  uint32_t currentSeq = ++comm->ceColl.ceSeqNum;

  // Write our own ready/complete flag to remote ranks
  uint32_t waitValue = capturing ? GRAPH_SYNC_VALUE : currentSeq;
  1. for (int r = 0; r < comm->nRanks; ++r) {
    if (r == comm->rank) continue;
    void * peerDstPtr;
    void* dstPtr = isComplete ? (void*)&completePtrs[comm->rank] : (void*)&readyPtrs[comm->rank];
    size_t offset = (uint8_t*)dstPtr - (uint8_t*)comm->ceColl.ceSyncWin->userPtr;
    NCCLCHECKGOTO(ncclDevrGetLsaRankPtr(comm, comm->ceColl.ceSyncWin, offset, r, &peerDstPtr), ret, fail);
    batchParams[*opIdx] = {};
    batchParams[*opIdx].writeValue.operation = CU_STREAM_MEM_OP_WRITE_VALUE_32;
    batchParams[*opIdx].writeValue.address  = (CUdeviceptr)peerDstPtr;
    batchParams[*opIdx].writeValue.value = waitValue;
    batchParams[*opIdx].writeValue.flags = CU_STREAM_WRITE_VALUE_DEFAULT;
    (*opIdx)++;
  }
  // Add local wait operations for every other rank
  2. for (int r = 0; r < comm->nRanks; ++r) {
    if (r == comm->rank) continue;
    batchParams[*opIdx] = {};
    batchParams[*opIdx].waitValue.operation = CU_STREAM_MEM_OP_WAIT_VALUE_32;
    batchParams[*opIdx].waitValue.address  = (CUdeviceptr)(isComplete ? (void*)&completePtrs[r] : (void*)&readyPtrs[r]);
    batchParams[*opIdx].waitValue.value = waitValue;
    batchParams[*opIdx].waitValue.flags = CU_STREAM_WAIT_VALUE_EQ;
    (*opIdx)++;
  }
}
```
1. 向远端GPU写操作(notify)：大致就是每个rank先去计算自己slots在远端rank内存内的地址 -> 计算相对偏移（target地址 - userPtr）-> LSA地址转换remote+offset -> 再把 `waitValue` 写到远端的对应的ready/complete内。（用了CU_STREAM_MEM_OP_WRITE_VALUE_32），但是重点是这里准备了后面LSA机制去访问其他rank对应的内存地址。
	如果是 ready 阶段：
offset = (ceSyncWin->userPtr + 0 + comm->rank * sizeof(uint32_t)) - ceSyncWin->userPtr
	如果是 complete 阶段：
offset = (ceSyncWin->userPtr + alignUp(nRanks*sizeof(uint32_t), 16) + comm->rank * sizeof(uint32_t)) - ceSyncWin->userPtr
2. 本地GPU等待操作：上面第二步的 `peerDstPtr` 变成现在的本地的GPU地址。

除了UCSync和MCSync的流程如下：
![[diff from 1 to 7 2025-10-13 19.50.43.excalidraw | 100%]]
## Step3: before launch

这里目标rank等于comm->rank的case就是自发自收，在nccl的enqueue.cc内对这种case的处理会中已经踢掉了sendbuff和recvbuff地址相同的情况。所以这里出现了dstRank == comm->rank的处理是对于处理alltoall场景的自发自收但是sendbuff != recvbuff的case；
在else分支内，alltoall会去遍历所有目标rank，src地址是本身mySendbuff+当前发了多少的地址。重点是这里peerRecvBuff，这个recv操作是在另一个gpu上的，这是跨进程拿回来的地址。这里同样是通过 `ncclDevrGetLsaRankPtr` api去算出来的LSA跨进程可以访问的address。
```cpp
for (int r = 0; r < comm->nRanks; r++) {
    int dstRank = (comm->rank + r) % comm->nRanks;
    uint8_t* srcPtr = mySendBuff + dstRank * chunkBytes;
    uint8_t* dstPtr = myRecvBuff + comm->rank * chunkBytes;
    
    if (dstRank == comm->rank) {
      // Local copy for own data
      batchOpsParams.srcs[batchOpsParams.numOps] = (void*)srcPtr;
      batchOpsParams.dsts[batchOpsParams.numOps] = (void*)dstPtr;
      batchOpsParams.sizes[batchOpsParams.numOps] = chunkBytes;
      batchOpsParams.numOps++;
    } else {
      // Remote copy to other ranks: send to rank dstRank's receive buffer at position comm->rank
      offset = dstPtr - (uint8_t*)args->recvWin->userPtr;
      NCCLCHECKGOTO(ncclDevrGetLsaRankPtr(comm, args->recvWin, offset, dstRank, &peerRecvBuff), ret, fail);
      batchOpsParams.srcs[batchOpsParams.numOps] = (void*)srcPtr;
      batchOpsParams.dsts[batchOpsParams.numOps] = (void*)peerRecvBuff;
      batchOpsParams.sizes[batchOpsParams.numOps] = chunkBytes;
      batchOpsParams.numOps++;
    }
  }
```
现在batchOpsParams内已经包含了同步操作，也包含了具体发送数据的所有信息。
## Step4: Launch Memory copy
这里在拷贝前判断了当前是不是numOps大于8和数据量大于512Mb，是的话就标记成当前是一个需要机内同步的组操作。然后直接launch真正的数据拷贝。
```cpp
batchOpsParams.intraBatchSync = (batchOpsParams.numOps > comm->ceColl.intraBatchSyncFreq && 
                                 chunkBytes*batchOpsParams.numOps >= comm->ceColl.intraBatchSyncMsgThreshold);
// Launch the batch operations
NCCLCHECKGOTO(ncclCeLaunchBatchOps(comm, &batchOpsParams, stream), ret, fail);
```
在ncclCeLaunchBatchOps内会看到cuda12.8-13.0支持的新的api，which is ` cudaMemcpyBatchAsync`。
```cpp
ncclResult_t ncclCeLaunchBatchOps(struct ncclComm* comm, struct ncclCeBatchOpsParams* params, cudaStream_t stream) {
  ......
  1. //--------------Graph capture--------------
  // cudaMemcpyBatchAsync is not supported during CUDA graph capture
  if (capturing) {...,等价于older CUDA versions执行的代码段}
  //--------------No graph capture--------------
  else {
    if (CUDART_VERSION >= 12080 && driverVersion >= 12080) {
#if CUDART_VERSION >= 12080
    // For CUDA 12.8+, use batch memory copy for better performance
    params->attrs[0] = {};
    params->attrs[0].srcAccessOrder = cudaMemcpySrcAccessOrderStream;
    params->attrs[0].flags = cudaMemcpyFlagPreferOverlapWithCompute;
    params->attrIdxs[0] = 0;
    params->numAttrs = 1;

    2. if (params->intraBatchSync) {
      // Break into multiple batches with sync between them
      int batchSize = comm->ceColl.intraBatchSyncFreq;
      for (int i = 0; i < params->numOps; i += batchSize) {
        int currentBatchSize = (i + batchSize <= params->numOps) ? batchSize : params->numOps - i;

        #if CUDART_VERSION >= 13000
        CUDACHECKGOTO(cudaMemcpyBatchAsync(
          &params->dsts[i], &params->srcs[i], &params->sizes[i], currentBatchSize,
          params->attrs, params->attrIdxs, params->numAttrs, stream), ret, fail);
        #else
        CUDACHECKGOTO(cudaMemcpyBatchAsync(
          &params->dsts[i], &params->srcs[i], &params->sizes[i], currentBatchSize,
          params->attrs, params->attrIdxs, params->numAttrs, nullptr, stream), ret, fail);
        #endif

        // Sync after each batch
        if (i + batchSize < params->numOps) {
          NCCLCHECKGOTO(ncclMemOpSync(comm, stream), ret, fail);
        }
      }
    3. } else {
      // Use single batch for all operations
      #if CUDART_VERSION >= 13000
      CUDACHECKGOTO(cudaMemcpyBatchAsync(
        params->dsts, params->srcs, params->sizes, params->numOps,
        params->attrs, params->attrIdxs, params->numAttrs, stream), ret, fail);
      #else
      CUDACHECKGOTO(cudaMemcpyBatchAsync(
        params->dsts, params->srcs, params->sizes, params->numOps,
        params->attrs, params->attrIdxs, params->numAttrs, nullptr, stream), ret, fail);
      #endif
    }
#endif
    } else {
      // For older CUDA versions, fall back to individual transfers
      for (int i = 0; i < params->numOps; i++) {
        CUDACHECKGOTO(cudaMemcpyAsync(
          (void*)params->dsts[i],
          (void*)params->srcs[i],
          params->sizes[i],
          cudaMemcpyDeviceToDevice,
          stream), ret, fail);
        if (params->intraBatchSync && ((i+1) % comm->ceColl.intraBatchSyncFreq == 0) && ((i+1) < params->numOps)) {
          NCCLCHECKGOTO(ncclMemOpSync(comm, stream), ret, fail);
        }
      }
    }
  }
}

```
1. 当前如果是cudaGraph开启或者cuda版本低于12.8，那么组操作就会按照numOps遍历，一个一个完成。
2. 如果是需要机内同步的批次，那么会通过intraBatchSyncFreq宏（value是8），按照8个op往上提交，而不是把几千个op一下推到stream上。然后每8个操作就会 `ncclMemOpSync` 同步一次。
3. op小于8个的话就直接一次性处理完。
## Step4：After launch
在把数据拷贝任务异步放到stream上之后，最后还进行了一次同步操作。
```cpp
NCCLCHECKGOTO(ncclMemOpSync(comm, stream), ret, fail);
```
至此就是ceAlltoall，简化一个case分析看就会知道为什么非对称内存是没法完成上面的实现的。
# 3. results
比如现在一个comm就俩个rank完成alltoall，或者再简化一些现在是inplace的情况，只剩下一对cudaMemcpyBatchAsync。这个新实现的api或者旧的cudaMemcpyAsync都不本质，无非就是发一次和发一组，问题在于这俩api内用的src和dst地址，特别是dst address。在非对称内存上，即使注册后，地址也是需要recveiver发起，sender才能正确拿到（cuMem会去交换fd跨进程能拿到）。当新旧api内用非对称的注册内存的地址的时候，我们没法提前知道receiver的地址在哪，这就导致我们一定得在gpu或者cpu侧（这里一定得是异步无阻塞的把任务下下去）去轮询出来正确的地址才能拷贝（尝试过给一个假地址，执行时刻更新真的地址，结果这俩api都会只用第一次给他的目标地址，导致拷贝出现地址不合法）。
而symmetric的出现，这个问题得到根本的解决，sender自己根据 `args-recvWin` 可以计算出收端的注册好的地址，这就是NVSHMEM的优势。