在transport.cc内的if (peer == comm->rank)逻辑内增加新的逻辑就是：把中转buffer的地址指针给sender的shm内直接发??

1. 单卡不需要自己再准备一个buffer，nccl内全部都直接跳过。
2. 在拷贝前从sendQueue和recvQueue内遍历出所有[bytes相等，sendbuff address != recvbuff address]的case，单独放个que，把任务在grouplaunch内下proxy op前直接处理后deque。

在flagcxProxyOps的结构体内加上:
```cpp
struct flagcxIntruQueue<struct flagcxSelfCopyTask, &flagcxSelfCopyTask::next> selfCopyQueue;
```
然后单独挑出单卡send recv的case：
```cpp
for (int i = 0; i < tasks->p2pOrderSteps; i++) {
        int peer = tasks->p2pOrder[i];
        
        // Process all self-send/recv pairs for this peer
        if (peer == comm->rank) {
          while (!flagcxIntruQueueEmpty(&tasks->peers[peer].sendQueue) &&
                 !flagcxIntruQueueEmpty(&tasks->peers[peer].recvQueue)) {
            
            flagcxTaskP2p *sendTask = flagcxIntruQueueHead(&tasks->peers[peer].sendQueue);
            flagcxTaskP2p *recvTask = flagcxIntruQueueHead(&tasks->peers[peer].recvQueue);
        if (sendTask->src address != recvTask->dst address) {
	        selfcopy->...
	        selfcopy->...
	        selfcopy->...
	        selfcopy->...
        }
        flagcxIntruQueueEnqueue(flagcxProxyOps<------selfcopy);

```
在grouplaunch内，按照flagcxProxyOps内的selfcopy结构体，遍历这个链表下memcopy任务。