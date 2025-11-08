在GPU内核当中，地址的交换通过device侧的函数setDaraPtrs的 `ptrExchange` 机制来实现：
```cpp
__device__ void setDataPtrs(void const *inputBuf, void *outputBuf, ...) {
  if (Direct && ipcReg) {
	  ...
    bool recvProvider = (flags & RoleWaitRecv) && (flags & DirectWrite);  // rank1接收方
    bool sendAcceptor = (flags & RoleWaitSend) && (flags & DirectWrite);  // rank0发送方
    
    if (recvProvider) {  // rank1执行
      // 接收方将自己的outputBuf地址放入ptrExchange共享给发送方
      void* volatile* slot = ncclShmem.groups[group].recvConns[index]->ptrExchange;
      directBuff = (T*)outputBuf;  // 本地输出缓冲区
      *slot = reinterpret_cast<void*>(outputBuf);  // 共享给对方
    }
    
    if (sendAcceptor) {  // rank0执行  
      // 发送方从ptrExchange获取接收方的输出缓冲区地址
      void* volatile* slot = ncclShmem.groups[group].sendConns[index]->ptrExchange;
      void* ptr;
      while (slot) {
        ptr = *slot;  // 读取接收方共享的地址
        if (ptr != nullptr) break;
      }
      directBuff = reinterpret_cast<T*>(ptr);  // 指向接收方的缓冲区
    }
    if (sendProvider) {...}
	  if (recvAcceptor) {...}
  }
}
```