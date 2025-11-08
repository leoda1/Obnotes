# 0 过程
通道数确定->树连接（option）->共享资源准备（credit）->数据缓冲准备(data ring)->runtime时用户缓冲注册（UB/Graph UB）->资源释放
![[nvls.cc 2025-10-09 14.26.10.excalidraw]]
# 1 通道数确定：ncclNvlsInit
这个函数就一个功能，支持NVLS的话，按照对应的架构和节点数选择一个比较好的 `comm->nvlsChannels`数。
* 看当前设备的cuda版本以及设备的能力，NCCL_NVLS_ENABLE=2是一个自动探测当前是否支持nvlsSupport。自动探测是拿着 `CU_DEVICE_ATTRIBUTE_MULTICAST_SUPPORTED` 去问驱动，当前是否支持multicast和reduction。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20251009114859873.png)
* 前面如果是comm->nvlsSupport =\=1的话，按架构与单/多节点给出 nvlsChannels，用户的配置也可覆盖。
```cpp
ncclResult_t ncclNvlsInit(struct ncclComm* comm) {
  comm->nvlsSupport = 0;
  comm->nvlsChannels = 0;

  int gpuCount;
  NCCLCHECK(ncclTopoGetGpuCount(comm->topo, &gpuCount));
  if (!ncclParamNvlsEnable() || gpuCount <= 2) return ncclSuccess;

  CUdevice dev;
  int driverVersion;

  if (CUPFN(cuDeviceGet) == NULL) return ncclSuccess;
  CUCHECK(cuCtxGetDevice(&dev));
  CUDACHECK(cudaDriverGetVersion(&driverVersion));
  if (ncclParamNvlsEnable() == 2) {
    // NVLS Multicast support requires CUDA12.1 UMD + KMD
    if (CUPFN(cuMulticastCreate) != NULL /*&& driverVersion >= 12010 */) {
      CUCHECK(cuDeviceGetAttribute(&comm->nvlsSupport, CU_DEVICE_ATTRIBUTE_MULTICAST_SUPPORTED, dev));
    }
  } else {
    comm->nvlsSupport = 1;
  }

  if (comm->nvlsSupport) {
    int channels;
    if (comm->compCap >= 100) {
      // Use a reduced number of channels for single node/MNNVL domain on Blackwell.
      // comm->nNodes is not yet initialized at this point so we need to use other data.
      bool multiNode;
      if (comm->MNNVL) {
        multiNode = (comm->clique.size < comm->nRanks);
      } else {
        int i;
        for (i = 1; i < comm->nRanks; i++) {
          if (comm->peerInfo[i].hostHash != comm->peerInfo[0].hostHash)
            break;
        }
        multiNode = (i < comm->nRanks);
      }
      channels = (multiNode ? NVLS_NCHANNELS_SM100 : NVLS_NCHANNELS_SM100_NVL);
    } else {
      channels = NVLS_NCHANNELS_SM90;
    }
    if (comm->config.nvlsCTAs != NCCL_CONFIG_UNDEF_INT) channels = comm->config.nvlsCTAs;
    comm->nvlsChannels = std::max(comm->config.minCTAs, std::min(comm->config.maxCTAs, channels));
  }
  INFO(NCCL_INIT, "NVLS multicast support is %savailable on dev %d (NVLS_NCHANNELS %d)",
       comm->nvlsSupport ? "" : "not ", dev, comm->nvlsChannels);
  return ncclSuccess;
}
```
# 2 多节点(NVLS head 间 P2P, option)
当 nNodes>1 时建立 NVLS head 的树型 P2P 通道（nvls.treeUp/treeDown[]），用于跨节点 reduce/bcast 的头尾段。
```cpp
ncclResult_t ncclNvlsTreeConnect(struct ncclComm* comm) {
  if (comm && comm->nvlsSupport && comm->nNodes > 1) {
    for (int c = 0; c < comm->nvlsChannels; c++) {
      struct ncclChannel* channel = comm->channels + c;
      NCCLCHECKGOTO(ncclTransportP2pConnect(comm, c, NCCL_MAX_NVLS_TREE_ARITY, channel->nvls.treeDown, 1, &channel->nvls.treeUp, 0), ret, fail);
      NCCLCHECKGOTO(ncclTransportP2pConnect(comm, c, 1, &channel->nvls.treeUp, NCCL_MAX_NVLS_TREE_ARITY, channel->nvls.treeDown, 0), ret, fail);
    }
    NCCLCHECKGOTO(ncclTransportP2pSetup(comm, &comm->graphs[NCCL_ALGO_NVLS], 0), ret, fail);
    INFO(NCCL_INIT, "Connected NVLS tree");
  }
  ...
}
```
# 3 共享资源准备（credit 区）：ncclNvlsSetup
大致如下：
* 裁剪 nvlsChannels，初始化通道
* 分配 UC 与 MC 的“信用区”内存、用来写head，tail，stepSize，异步推到devPeersHostPtr[]
* UB注册一个本地的shared memory，低开销的广播，用来同步偏移。
```cpp
ncclResult_t ncclNvlsSetup(struct ncclComm* comm, struct ncclComm* parent) {
  ...
  bool nvlsShare = parent && parent->nvlsSupport && parent->shareResources && parent->localRanks == comm->localRanks;
  1. if (comm->nvlsSupport == 0 || comm->nvlsChannels == 0) return ncclSuccess;
  2. comm->nvlsChunkSize = ncclParamNvlsChunkSize();
  3. if (nvlsShare) { ... } else {
    4. struct ncclNvlsSharedRes* resources = NULL;
    struct ncclNvlsSharedRes* resources = NULL;
    int nHeads = comm->channels[0].nvls.nHeads;
    int nChannels = comm->nvlsChannels;
    size_t memSize = 64;
    size_t creditSize = nChannels * 2 * memSize * nHeads;
    int nvlsStepSize = comm->nvlsChunkSize;
    cudaStream_t hostStream, deviceStream;
    ...
    NCCLCHECKGOTO(ncclCalloc(&comm->nvlsResources, 1), res, fail);
    comm->nvlsResources = ...;  
    comm->nvlsResources->nChannels = comm->nvlsChannels;
    for (int c = 0; c < nChannels; c++) {
      NCCLCHECKGOTO(initNvlsChannel(comm, c, NULL, false), res, fail);
    }
    ...
    NCCLCHECKGOTO(nvlsAllocateMem(comm, &resources->accessDesc, creditSize, &resources->ucCreditHandle, &resources->mcCreditHandle, (void**)&resources->ucCredit, (void**)&resources->mcCredit, &resources->creditUCSize, &resources->creditMCSize), res, fail);
    ...
    for (int h = 0; h < nHeads; h++) {
      int nvlsPeer = comm->nRanks + 1 + h;
      for (int c = 0; c < nChannels; c++) {
        struct ncclChannel* channel = comm->channels + c;
        char* mem = NULL;
        struct ncclChannelPeer* peer = channel->peers[nvlsPeer];
        // Reduce UC -> MC (send[1], recv[0]) 与 Broadcast MC -> UC (recv[1], send[0]) 信用区
        mem = resources->ucCredit + (h * 2 * nChannels + c) * memSize;
        peer->send[1].transportComm = &nvlsTransport.send;
        ...
        mem = resources->mcCredit + (h * 2 * nChannels + c) * memSize;
        peer->recv[0].transportComm = &nvlsTransport.recv;
        ...
        mem = resources->ucCredit + ((h * 2 + 1) * nChannels + c) * memSize;
        peer->recv[1]....
        mem = resources->mcCredit + ((h * 2 + 1) * nChannels + c) * memSize;
        peer->send[0]....
        // 推送 conn 到设备可见
        CUDACHECKGOTO(cudaMemcpyAsync(&comm->channels[c].devPeersHostPtr[nvlsPeer]->send[0], &peer->send[0].conn, sizeof(struct ncclConnInfo), cudaMemcpyHostToDevice, hostStream), res, fail);
        ...
      }
    }
    ...
    // UB 注册辅助的本地共享内存
    if (!comm->MNNVL && comm->nvlsResources->nvlsShmemHandle == NULL) {
      ...
    }
  }
  ...
}
```
1. 入口看当前如果不支持nvls或者nvlsChannels是0就会直接退出
2. 选择chunksize（128KB），这个也是后面的stepSize，设备端每次前进的数据的步长就是这个。
3. parent可以复用的话就会直接复用parent的nvls资源。并把每个通道重新init一遍。
4. 不能复用就会新建资源（给分配UC和MC的信用区内存的时候用），分配了堆上的资源（`comm->nvlsResources`），并把前面ncclNvlsInit获得的channels(CTAs)数、nvls头数等等都填写进去。之后，为每个通道initNvlsChannel，去填好channels->nvls的up/down端口，给后续device侧用。注：这里有memSize = 64（每个“信用区”64字节）。creditSize =nChannels * 2 * memSize * nHeads。2表示两个方向：Reduce（UC->MC）与 Broadcast（MC->UC）。
	当准备好以上的资源区，调用 `nvlsAllocateMem()` 分配UC和MC的”信用区“内存，第4小节单说这个 `nvlsAllocateMem`。
# 4 UC/MC 分配与映射（共享函数）：nvlsAllocateMem
被两处调用：
* ncclNvlsSetup 阶段：为 credit 区分配/映射 UC/MC 小块；
* ncclNvlsBufferSetup 阶段：为 data ring 分配/映射 UC/MC 大块。

创建/导入 MC 句柄 → 加入组 → 分配并映射 UC → 所有本地 rank barrier → 绑定 UC→MC → 为 MC VA 保留/映射 → 设置访问权限。
```cpp
static ncclResult_t nvlsAllocateMem(..., size_t size, ..., void** ucptr, void** mcptr, size_t* ucsizePtr, size_t* mcsizePtr) {
  char shareableHandle[NVLS_HANDLE_SIZE];
  ...
  mcprop.numDevices = comm->localRanks;
  mcprop.size = size;
  1. CUCHECKGOTO(cuMulticastGetGranularity(&mcgran, &mcprop, CU_MULTICAST_GRANULARITY_RECOMMENDED), ret, fail);
  ...
  2. if (comm->localRank == 0) {
    NCCLCHECKGOTO(ncclNvlsGroupCreate(..., &mcHandle, shareableHandle), ret, fail);
    NCCLCHECKGOTO(bootstrapIntraNodeBroadcast(..., shareableHandle, NVLS_HANDLE_SIZE), ret, fail);
  } else {
    NCCLCHECKGOTO(bootstrapIntraNodeBroadcast(..., shareableHandle, NVLS_HANDLE_SIZE), ret, fail);
    NCCLCHECKGOTO(ncclNvlsGroupConnect(..., shareableHandle, ..., &mcHandle), ret, fail);
  }
  3. CUCHECKGOTO(cuMulticastAddDevice(mcHandle, comm->cudaDev), ret, fail);
  // 分配/映射 UC
  ucprop.type = CU_MEM_ALLOCATION_TYPE_PINNED; ...
  4. CUCHECKGOTO(cuMemGetAllocationGranularity(&ucgran, &ucprop, CU_MEM_ALLOC_GRANULARITY_RECOMMENDED), ret, fail);
  5. CUCHECKGOTO(cuMemAddressReserve((CUdeviceptr*)ucptr, ucsize, ucgran, 0U, 0), ret, fail);
  6. CUCHECKGOTO(cuMemCreate(ucHandle, ucsize, &ucprop, 0), ret, fail1);
  7. CUCHECKGOTO(cuMemMap((CUdeviceptr)*ucptr, ucsize, 0, *ucHandle, 0), ret, fail2);
  8. CUCHECKGOTO(cuMemSetAccess((CUdeviceptr)*ucptr, ucsize, desc, 1), ret, fail3);
  9. CUDACHECKGOTO(cudaMemset(*ucptr, 0, ucsize), ret, fail3);
  // 所有本地 rank barrier，避免 BindMem 阶段竞态
  NCCLCHECKGOTO(bootstrapIntraNodeBarrier(...), ret, fail3);
  // 绑定 UC → MC（易失败的系统点，失败时可降级）
  {
  10.   CUresult err = CUPFN(cuMulticastBindMem(*mcHandle, 0, *ucHandle, 0, ucsize, 0));
    if (err != CUDA_SUCCESS) { ... 降级/报错 ... }
  }
  // 为 MC VA 保留/映射
  11. CUCHECKGOTO(cuMemAddressReserve((CUdeviceptr*)mcptr, mcsize, mcgran, 0U, 0), ret, fail);
  12. CUCHECKGOTO(cuMemMap((CUdeviceptr)*mcptr, mcsize, 0, *mcHandle, 0), ret, fail);
  13. CUCHECKGOTO(cuMemSetAccess((CUdeviceptr)*mcptr, mcsize, desc, 1), ret, fail);
  ...
}
```
看 `nvlsAllocateMem` 代码需要先去了解一遍cuda的[[6.16. Multicast Object Management(组播对象管理)]] and [[6.14 Virtual Memory Management(VMM)]]。
https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__MULTICAST.html#group__CUDA__MULTICAST
1. 先获取multicast对象推荐的粒度和属性结构体mcprop。
2. comm->localRank=\=0的progress负责创建NVSwitch Multicast对象（MC），在 `ncclNvlsGroupCreate` 内可以看到是 `CU_MEM_HANDLE_TYPE_FABRIC` 的话就会调用 `cuMemExportToShareableHandle` 把当前handle导出成shareable handle。并用bootstrap把这个shareableHandle广播出去，其他rank则接收这个shareable handle。**这一步需要init.cc内调用ncclMnnvlCheck()的时候给ncclCuMemHandleType的类型赋值为FABRIC类型**。
	comm->localRank!=0的gpu就会去把上面的shareable handle导入成自己的mcHandle。
3. 所有的rank在自己的进程内都拿到了mcHandle之后，把自己comm内的cudaDev都加到这个组播的对象内。这个组播对象并不自带物理内存，不负责VMM分配，只是NVSwitch上需要组播的成员集合。接下来就是unicast handle来在各自设备上分配GPU上实际存在的物理页。
4. 计算对齐粒度 ucgran，按推荐粒度对齐 ucsize。
5. 预留VA
6. 在本 GPU 分配物理页
7. 把物理页映射到 ucptr
8. 设置访问
9. 清零，再做一次本机 barrier，避免 abort 时 bind 阶段卡住
10. 把“这个 GPU 的这块物理内存”作为 MC 对象在偏移 0 的后备存储之一。所有成员 GPU 都要做各自的 BindMem，同一个 MC 偏移上形成“多副本”
11. 在本进程地址空间保留一段对齐的虚拟地址区间，返回起始地址到 mcptr。此时不占用物理页，不可访问。
12. 把刚预留的 VA 区间映射到你手里的“MC 句柄”
13. 给这段 VA 在当前设备上设置访问权限（desc 里是 PROT_READWRITE 和 device location）
