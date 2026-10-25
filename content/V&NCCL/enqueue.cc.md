## 0. overall
## 1. addP2pToplan()
大致是send recv传输操作加到执行计划内：
1. 判断当前是机内还是机间
2. 注册buffer，机间就是 `ncclRegisterP2pNetBuffer`，机内就是 `ncclRegisterP2pIpcBuffer`，这里会去transport层找自己的register buffer的具体实现
3. 生成设备工作结构，`ncclDevWorkP2p`
4. 为非自发送创建proxy操作
机间注册buffer的时候会多一步判断，必须得保证PXN是关闭的。并且会给每个channel都注册buffer。
```cpp
bool pxnUsed = !ncclPxnDisable(comm) && comm->isAllNvlink && comm->maxLocalRanks > 1;
if (bytes[dir] > 0 && proxySameProcess[dir] && protocol[dir] == NCCL_PROTO_SIMPLE && (!pxnUsed)) {
        int regFlag = 0;
        NCCLCHECK(ncclCalloc(&handles[dir], nChannelsMax));
        for (int part = 0; part < nChannelsMax; part++) {
          int channelId = ncclP2pChannelForPart(comm->p2pnChannels, base, part);
          struct ncclChannelPeer** channelPeers = comm->channels[channelId].peers;
          int peerRank = dir ? sendRank : recvRank;
          struct ncclConnector* conn = dir ? &channelPeers[peerRank]->send[connIndex]
            : &channelPeers[peerRank]->recv[connIndex];
          if (conn->conn.flags & NCCL_DIRECT_NIC)
            ncclRegisterP2pNetBuffer(comm, addrs[dir], bytes[dir], conn, &regFlag, &handles[dir][part], &plan->cleanupQueue);
          if (!regFlag) break;
        }
        netRegistered[dir] = regFlag ? true : false;
      }
```
机内的话发现，有实际数据，有地址是simple协议和非selfsend就会去注册ipcbuffer。注册具体流程：ncclRegisterP2pIpcBuffer在transport/[[sendrecv_reg]]内（fd和handle去交换拿到的注册buffer）：
这里举例说比如机内rank0发给rank1。那么rank0是sender，对应这里时dir=1的情况，sender把自己的地址addr[1]`放进ncclRegisterP2pIpcBuffer` 内拿到对端注册的 `regAddr` ，但是它 `sendAddr = regAddr`，也就是说把对端注册的buffer地址覆盖了自己的sendAddr。同理receiver也是这样，通过完成注册后打印看到刚刚的举例真实情况如下：
```shell
node201:41510:41510 [0] NCCL INFO rank[0] addP2pToPlan: sendRank=1, sendAddr=0x7f561c200000, sendBytes=4194304, recvRank=1, recvAddr=(nil), recvBytes=-1
node201:41511:41511 [1] NCCL INFO rank[1] addP2pToPlan: sendRank=0, sendAddr=(nil), sendBytes=-1, recvRank=0, recvAddr=0x7f670e600000, recvBytes=4194304
```
在[[p2p.cc]]内的连接阶段会决定read/write模式, 根据read模式，发送方和接收方的连接会设置不同的flags，我当前rank1（接收方）具有NCCL_P2P_WRITE标志。
```cpp
static ncclResult_t p2pGetInfo(struct ncclComm* comm, struct ncclPeerInfo* info1, struct ncclPeerInfo* info2, int* read, int* intermediateRank) {
	// 通过拓扑检查决定是否使用read模式（通常在Ampere+NVLink时启用）
	NCCLCHECK(ncclTopoCheckP2p(comm, comm->topo, info1->rank, info2->rank, &p2p, read, intermediateRank));
	// 参数可以强制覆盖
  int readEnable = ncclParamP2pReadEnable();
  if (readEnable != -2) *read = readEnable;
}
```
就是说最简单场景的时候，sender只知道自己地址 字节 发给谁，receiver知道只自己地址 字节 收谁。但是各自的进程都没有对方的信息。那么原生的话 rank0 dir=1 和rank1 dir=0会走addP2pToPlan。现在rank1的ncclRegisterP2pIpcBuffer拿到regFlag(是 rank0 进程中指向 rank1 内存的虚拟地址)，conn->conn.flags导致只有rank1走到recvAddr = regAddr;内。打印日志看到NCCL INFO rank[1] run into dir == 0, now is NCCL_P2P_WRITE。现在rank0和rank1各自进程里面的work内，只有rank1的work内work->recvAddr是拿到的regAddr。具体work内怎么在一个进程里面拿到send recv地址完成拷贝的内容在:[[prims_simple.h]]
rank1收端通过 `ncclRegisterP2pIpcBuffer` 让rank0发端可以跨进程访问rank1注册后的recvbuff的地址，当前是write。在[[prims_simple.h]]内会让rank1收端当地址的Provider，因为它已经准备好了send端跨进程的地址，但是这个地址需要给send的进程，所以这个地址会放到一个共享内存里，让sender的recvAddr（Acceptor）来取这个地址，这样sender视角自己的sendAddr是自己进程的，自己的recvAddr也是自己进程的（可以访问对端进程的地址）[[sendrecv_reg]]结尾对这个过程有总结。
```cpp
else if (bytes[dir] > 0 && addrs[dir] && protocol[dir] == NCCL_PROTO_SIMPLE && !selfSend) {
      int peerRank = dir ? sendRank : recvRank;
      int regFlag = 0;
      int channelId = ncclP2pChannelForPart(comm->p2pnChannels, base, 0);
      struct ncclChannelPeer** channelPeers = comm->channels[channelId].peers;
      struct ncclConnector* conn = dir ? &channelPeers[peerRank]->send[connIndex]
        : &channelPeers[peerRank]->recv[connIndex];
      void* regAddr = NULL;
      // [NCCL_P2P_WRITE] 表示可以写入对端内存
			// [NCCL_P2P_READ]  表示可以从对端内存读取
      if (conn->conn.flags & (NCCL_P2P_WRITE | NCCL_P2P_READ)) {
        // 双方都需要注册 注册后可以直接访问的对端的内存地址就是regAddr
        NCCLCHECK(ncclRegisterP2pIpcBuffer(comm, addrs[dir], bytes[dir], peerRank, &regFlag, &regAddr, &plan->cleanupQueue));
        if (regFlag) {
          if (dir == 0 && (conn->conn.flags & NCCL_P2P_WRITE)) recvAddr = regAddr;
          else if (dir == 1 && (conn->conn.flags & NCCL_P2P_READ)) sendAddr = regAddr;
        }
      }
      ipcRegistered[dir] = regFlag ? true : false;
    }
```
selfsend就是单进程，只下一个proxyOp。非selfsend就是涉及进程间的传输，就下两个proxyop，dir=0是recv，dir=1是send。
```cpp
struct ncclProxyOp proxyOps[2] = {};
int nProxyOps = selfSend ? 0 : 2;
```
原生nccl注册后也会走到 `device/sendrecv.h内的runSend和runRecv`。
```cpp
template<typename Proto>
__device__ void runSend(int tid, int tn, int group, struct ncclDevWorkP2p* work) {
  Primitives<T, RedOp, FanAsymmetric<0, 1>, 1, Proto, 1>
    prims(tid, tn, nullptr, &work->sendRank, 
          work->sendAddr,    // 发送缓冲区 (inputBuf)
          nullptr,           // 接收缓冲区 (outputBuf=nullptr)
          0, group, 1, 1, nullptr, work, stepSize);
}
__device__ void runRecv(int tid, int tn, int group, struct ncclDevWorkP2p* work) {
  Primitives<T, RedOp, FanAsymmetric<1, 0>, 1, Proto, 1>
    prims(tid, tn, &work->recvRank, nullptr,
          nullptr,           // 发送缓冲区 (inputBuf=nullptr)
          work->recvAddr,    // 接收缓冲区 (outputBuf)
          0, group, 1, 1, nullptr, work, stepSize);
}
```
## 2. xxxTaskAppend
在`taskAppend`内会对不同的任务走不同任务入队。
```cpp
static ncclResult_t taskAppend(struct ncclComm* comm, struct ncclInfo* info) {
    ncclFunc_t collAPI = info->coll;
    if (info->coll == ncclFuncSend || info->coll == ncclFuncRecv) {
        NCCLCHECK(p2pTaskAppend(comm, info, info->coll, collAPI, (void*)info->recvbuff, info->count, info->datatype, info->root, true));
    } else if (info->coll == ncclFuncPutSignal || info->coll == ncclFuncSignal || info->coll == ncclFuncWaitSignal) {
        NCCLCHECK(rmaTaskAppend(comm, info));
    } else if (info->coll == ncclFuncAlltoAllV) {
        NCCLCHECK(rmaCollTaskAppend(comm, info, info->rmacoll, info->rmaAPI, info->datatype));
    } else {
        // ...
    }
  
```
### 2.1 rmaTaskAppend
只有三个API会走这里，包括：`ncclPutSignal`， `ncclSignal` 和 `ncclWaitSignal`。
* WaitSignal（多源等待）：把 info->signalDescs[ ] 转成两段数组 t->peers[ ]、t->nsignals[ ]，表示“要等待哪些 peer 的信号、每个 peer 要等多少次 opCnt”。
* Signal（纯 signal）：生成一个 ncclTaskRma，但它本身没有数据搬运（你这里把 count 约束为 0），更像是“发信号”的控制类任务。
* PutSignal（搬运+最后发信号）：生成一个或多个 ncclTaskRma（可能切分），每个 task 携带 src/peer 的 window + offset + bytes；只有最后一个 chunk 的 signalMode 才是 NCCL_SIGNAL，前面的 chunk 用 NCCL_SIGNAL_NONE，避免每块都发信号。
这里的任务入队
```cpp
static ncclResult_t rmaTaskAppend(
    struct ncclComm* comm,
    struct ncclInfo* info) {
    struct ncclKernelPlanner *planner = &comm->planner;
    void const* srcBuff = info->sendbuff;
    // Initialize window pointers - only needed for Put and Signal
    struct ncclDevrWindow* peerWinHost = NULL;
    struct ncclDevrWindow* srcWinHost = NULL;
    size_t srcWinOffset = 0;
    // 只有PutSignal操作计算peerWinHost和srcWinOffset
    if (info->coll == ncclFuncPutSignal) {
        struct ncclWindow_vidmem* peerWinDevHost = NULL;
        NCCLCHECK(ncclShadowPoolToHost(&comm->devrState.shadows, info->peerWin, &peerWinDevHost));
        peerWinHost = (struct ncclDevrWindow*)peerWinDevHost->winHost;
        NCCLCHECK(ncclDevrFindWindow(comm, srcBuff, &srcWinHost));
        srcWinOffset = (char*)srcBuff - (char*)srcWinHost->userPtr;
    }
    
  
```