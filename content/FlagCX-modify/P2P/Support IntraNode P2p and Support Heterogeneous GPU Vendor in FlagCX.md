# 0 architecture
FlagCX内对hostfunc有两种实现，都可用deviceAdaptor来正确调用，此外proxy progress被hostfunc正常触发之后实际的cudaMemcpyAsyc也有deviceAdaptor来正确调用。
但是与net.cc内不同的是机内p2p需要共享内存来完成数据的/同步信号的跨进程读写。综上整个p2p需要实现的话需要如下结构：
![[Support IntraNode P2p and Support Heterogeneous GPU Vendor in FlagCx 2025-10-20 15.32.45.excalidraw | 100%]]
# 1 FlagCX Adaptor
跨GPU通过bootstrap去交换的是 CUmemAllocationHandleType_enum，我们需要在flagcx内至少支持其中一类，比如 CU_MEM_HANDLE_TYPE_POSIX_FILE_DESCRIPTOR(fd) 。

此外，nvidia以外厂商需要支持如下类似虚拟内存管理的结构体和接口：
[[6.14 Virtual Memory Management(VMM)]]，调整为使用Ipc，不使用cuMem。

## 1.1 flagcx pr-272
flagcxDeviceAdaptor和对应实例内增加接口如下： 

|     | API                | nvidia                |
| --- | ------------------ | --------------------- |
| 1   | ipcMemHandleOpen   | cudaIpcOpenMemHandle  |
| 2   | ipcMemHandleClose  | cudaIpcCloseMemHandle |
| 3   | ipcMemHandleGet    | cudaIpcGetMemHandle   |
| 4   | ipcMemHandleCreate | flagcxCalloc          |
| 5   | ipcMemHandleFree   | 直接free                |
sharedbuffer则是把nccl的shm.cc内的cuMemDisable情况的ncclShmAllocateShareableBuffer和ncclShmImportShareableBuffer搬了过来。这里实现的逻辑参考[[shm.cc]]。


## 1.2 还需要的

|     | CUDA API                                | Describe                                               |
| --- | --------------------------------------- | ------------------------------------------------------ |
| 1   | ~~cudaThreadExchangeStreamCaptureMode~~ | 放宽stream当前模式为宽松，允许cudaMalloc。防止当前在捕获期间，出现不安全cudaMalloc |
| 2   | ~~cudaDeviceEnablePeerAccess~~          | receiver创建RecvFifo的时候需要设置当前GPU可被对端访问                   |
# 2 Specific
## 2.1 分配GPU上的内存以及CPU上的物理页给两个进程使用
1. 用proxy先去触发 让sender和receiver各自去准备自己需要共享的东西。
2. 然后transport内connectInfo内填写desc，用bootstrap互相交换connectInfo。
3. 再各自调用connect去把desc转换成各自需要的东西。
### 2.1.1 shm buffer
sender在自己的proxy setup阶段去调用shmutils.cc内的flagcxShmAllocateShareableBuffer。
⚠️注意：
1. 在flagcx内环境变量 `FLAGCX_ENABLE_TOPO_DETECT` 默认是关，就不会走initTransportsRank（fillPeerInfo，bootstrapAllGather等），所以就不会有 `comm->peerInfo`，会coredump。

```cpp
Sender (rank 0):
  conn->proxyConn.connection->transportResources = resources_sender
    ├─ sendDevMem (自己的发送缓冲区，不用)
    ├─ recvDevMem (对方的接收缓冲区，导入的)
    └─ proxyInfo_sender
         ├─ shm (指向共享内存)
         ├─ desc（导receiver开辟的buffer）
         ├─ stream
         └─ events[MAXSTEPS--16]

Receiver (rank 1):
  conn->proxyConn.connection->transportResources = resources_receiver
    ├─ recvDevMem (自己的接收缓冲区，分配的)
    ├─ sendDevMem (对方的发送缓冲区，不用)
    └─ proxyInfo_receiver
         ├─ shm (指向共享内存)
         ├─ desc（自己的进程的不用导）
         ├─ stream
         └─ events[MAXSTEPS--16]
```
