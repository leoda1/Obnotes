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
需要2-3个，讨论？功能如下，看怎么玩起来。
![[Asymmetric Register P2p(Zerocopy) 2025-11-14 17.24.04.excalidraw.png]]

## 3. Proxy发送/接收修改（主要功能点2）
recv的progress写地址，send拿到直接拷贝。
## 4. 资源清理
在 flagcxP2pSendProxyFree 和 flagcxP2pRecvProxyFree 中：
* 调用 cudaIpcCloseMemHandle 关闭远端映射
* 释放 regInfo 结构内存
