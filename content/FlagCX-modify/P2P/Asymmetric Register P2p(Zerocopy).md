## 1. 数据结构扩展 (p2p.h)
下面的结构体为注册相关：
```cpp
struct flagcxP2pIpcRegInfo {
  void* baseAddr;           // 本地注册buffer的基地址
  void* rmtRegAddr;         // 远端映射后的地址
  size_t offset;            // userbuff相对baseAddr的偏移
  cudaIpcMemHandle_t ipcHandle; // CUDA IPC handle
  int peerRank;
};
```
下面的结构体为实际传输相关：
```cpp
struct flagcxP2pRegInfo {
  int copyDone;
  int copyStarted;
  int receiverReady;
  void* receiverRegAddr;
  ssize_t receiverRegBytes;
};
```
这里的flagcxP2pRegInfo需要丢到shm结构体去，初始化阶段就要开出来。
## 2. 注册函数(主要功能点1)
需要在flagcxCommRegister的时候pair两种，net和p2p的注册handle。然后通过proxy打开handle，在用的时候proxy去写到shm内告诉sender往哪里发送数据。
### Who open the Handle and how to open
在nccl的receiver自己拿到handle之后会去调用proxy，如下：
```cpp
if (proxyConn) {
    INFO(NCCL_REG, "rank %d - IPC registering buffer %p size %ld (baseAddr %p size %ld) to peer %d", comm->rank, userbuff, buffSize, (void*)regRecord->addr, ipcInfo.size, peerRank);
    NCCLCHECKGOTO(ncclProxyCallBlocking(comm, proxyConn, ncclProxyMsgRegister, &ipcInfo, sizeof(p2pIpcExpInfo), &rmtRegAddr, sizeof(void*)), ret, fail);
}
```
这里的proxyConn是：ncclProxyConnect(comm, TRANSPORT_P2P, 1, peerRank, ...) 建立的是到 peerRank 的 proxy 连接。所以 `ncclProxyCallBlocking` 发送的消息是发到对端peer的proxy线程去。
```cpp
if (comm->gproxyConn[peerRank].initialized == false) {
	NCCLCHECKGOTO(ncclProxyConnect(comm, TRANSPORT_P2P, 1, peerRank, &comm->gproxyConn[peerRank]), ret, fail);
}
proxyConn = &comm->gproxyConn[peerRank];
```
对端的proxy收到后，调用 p2pProxyRegister 函数去open传过来的handle变成自己进程里面可以使用的地址。
```cpp
static ncclResult_t p2pProxyRegister(struct ncclProxyConnection* connection, 
    struct ncclProxyState* proxyState, void* reqBuff, ...) {
    
    struct p2pIpcExpInfo* ipcExpInfo = (struct p2pIpcExpInfo*)reqBuff;
    
    // 对端 proxy 在自己的 CUDA context 中打开 IPC handle
    if (ipcExpInfo->legacyIpcCap) {
        // 使用 cudaIpcOpenMemHandle 打开发送方导出的 IPC handle
        cudaIpcOpenMemHandle(&regAddr, ipcExpInfo->ipcDesc.devIpc, ...);
    } else {
        // cuMem API 方式
        cuMemImportFromShareableHandle(&handle, ...);
        cuMemMap(...);
    }
    
    // 返回本地映射后的地址
    *(void**)respBuff = regAddr;
}
```
以上是nccl内在bootstrap阶段 `ringAllInfo`函数内调用 `bootstrapAllGather` 收集所有rank的proxy监听地址才支持的当前进程连接其他进程的proxy。


![[Asymmetric Register P2p(Zerocopy) 2025-11-14 17.24.04.excalidraw.png]]
## 3. Proxy发送/接收修改（主要功能点2）
recv的progress写地址，send拿到直接拷贝。
## 4. 资源清理
在 flagcxP2pSendProxyFree 和 flagcxP2pRecvProxyFree 中：
* 调用 cudaIpcCloseMemHandle 关闭远端映射
* 释放 regInfo 结构内存
