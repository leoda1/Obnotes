### ncclP2pSchedule
前面都是算一些基础需要的变量。在核心逻辑内：
* 由sendGroup和recvGroup做第一层循环
![[init.cc 2026-01-26 20.23.41.excalidraw.svg]]%%[[init.cc 2026-01-26 20.23.41.excalidraw|🖋 Edit in Excalidraw]]%%


```cpp
static ncclResult_t ncclP2pSchedule(struct ncclComm* comm) {
    struct ncclNodeRanks* nodeRanks = comm->nodeRanks; // 按节点存的rank信息 
    int groupSize = (comm->nNodes > 1) ? ncclParamGroupSize() : comm->maxLocalRanks;// 默认8个rank一个group
    int local = comm->localRank % groupSize; // 当前rank在group内的id
    int group = comm->localRank / groupSize; // 当前rank的group id
    int nGroups = comm->nRanks / groupSize;  // 总group数量
    int nGroupsPow2 = pow2Up(nGroups); // 假如nGroups是7，那么nGroupsPow2就是8
    // 假如前面ncclParamGroupSize()指定的是4个rank一组的话，那么下面的代码就会算出来
    // groupToNode[x] ： 第x个group在哪个节点
    // groupToLocal[x] ：第x个group在当前节点上组内的起始rank index
    int *groupToNode, *groupToLocal;
    for (int n = 0; n < comm->nNodes; ++n) {
        int nGroupsInNode = comm->nodeRanks[n].localRanks / groupSize;
        for (int g = 0; g < nGroupsInNode; ++g) {
          groupToLocal[groupCount] = g * groupSize;
          groupToNode[groupCount] = n;
          groupCount++;
        }
        if (n < comm->node) group += nGroupsInNode;
    }
    
    /* 核心逻辑 */
    uint32_t groupRound = 0, groupDelta = 0; int round = 0;
    do {
        if (groupDelta < nGroups) { // Filter nonsensical group deltas
          int sendGroup = (group + groupDelta) % nGroups;
          int recvGroup = (group - groupDelta + nGroups) % nGroups;
          int sendNode = groupToNode[sendGroup];
          int recvNode = groupToNode[recvGroup];
          for (int delta = 0; delta < groupSize; delta++) {
            int sendLocal = groupToLocal[sendGroup] + (local + delta) % groupSize;
            int recvLocal = groupToLocal[recvGroup] + (local - delta + groupSize) % groupSize;
            comm->p2pSchedule[round].sendRank = nodeRanks[sendNode].localRankToRank[sendLocal];
            comm->p2pSchedule[round].recvRank = nodeRanks[recvNode].localRankToRank[recvLocal];
            comm->p2pSchedule[round].sendNode = sendNode;
            comm->p2pSchedule[round].recvNode = recvNode;
            round += 1;
          }
        }
        groupRound += 1;
        groupDelta = (groupDelta + groupRound) & (nGroupsPow2 - 1); // Quadratic update
    } while (groupRound != nGroupsPow2);
    
  
}
```