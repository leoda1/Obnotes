## 1. 问题
无核的psm_p2p.cc传输层内 `canConnect` 内 `ncclTopoCheckP2p` 怎么不影响p2p。
## 2.现象
1. Q：NCCL_SHM_DISABLE=1的时候会间接影响topo，跳过p2p，跳过shm都得正确。
	A：src/graph/paths.cc::ncclTopoComputePaths()
	![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250905111615361.png)
2. 当我 `ncclTopoComputePaths` 的 `system->nodes[GPU].nodes[p].paths[GPU][g].type = PATH_NET;` 生效之后，貌似对原生的cc操作有影响。
* init阶段调用 `initTransportsRank` 走到 `ncclTopoComputePaths` 内，系统分析硬件topo，确定GPU间物理连接路径类型（PATH_NET, PATH_NVL等等），这里用了canConnect将不能。
* transfer阶段，在 transport.cc 内的 `selectTransport` 函数内用canConnect，按照优先顺序尝试不同的传输方式，p2p、shm、net等。

两个阶段都会用传输层的canConnect，在标记成PATH_NET之后，会在后续的 `ncclTopoTrimSystem` 内被处理。具体逻辑就是如果两个GPU之间的路径类型 < PATH_NET（即PATH_NVL、PATH_PIX、PATH_PXB等），它们会被归入同一域。如果路径类型 = PATH_NET，它们会被归入不同域。PATH_NET的宏定义是9，是最大路径类型值。当路径类型被设置为PATH_NET时，
```cpp
ncclResult_t ncclTopoTrimSystem(struct ncclTopoSystem* system, struct ncclComm* comm) {
	...
	// 1. 这里domain把 < PATH_NET的变成一个域
	for (int g=0; g<system->nodes[GPU].count; g++) {
    struct ncclTopoNode* gpu = system->nodes[GPU].nodes+g;
    domains[g] = g;
    ids[g] = gpu->id;
    for (int p=0; p<g; p++) {
      if (gpu->paths[GPU][p].type < PATH_NET) {
        domains[g] = std::min(domains[g], domains[p]);
      }
    }
    if (gpu->gpu.rank == comm->rank) myDomain = domains[g];
  }
  // 2. 删除不同域的GPU
  for (int i=0; i<ngpus; i++) {
        if (domains[i] == myDomain) continue;  // 保留同域的GPU
        NCCLCHECKGOTO(ncclTopoRemoveNode(system, GPU, g), ret, fail);
        ...
    }
  // 3. 单节点的话，删除所有NIC
  if (system->nodes[GPU].count == comm->nRanks) {
    for (int n=system->nodes[NET].count-1; n>=0; n--)
      NCCLCHECKGOTO(ncclTopoRemoveNode(system, NET, n), ret, fail);
  }
}
```
* 单节点，删除了所有NIC节点（拓扑被简化），使用P2P或者SHM去通信
* 多节点，网路通信通过系统调用访问网卡，NIC在这里被删除是不影响net的，net传输是运行时动态发现和选择网络设备，通过插件实现的。

所以如果 `system->nodes[GPU].nodes[p].paths[GPU][g].type = PATH_NET` 就会导致单节点的topo直接被删除。nccl会让这里的topo变成net动态找到的网络通信路径。这可能就会导致机内的reducescatter等出现没有topo的问题。

3. 我需要无核的zerocopy的机内走net，保留原来p2p和shm的topo，千万不能两者都disable（会导致变成PATH_NET，然后直接被简化没了）。怎样比较合理可以实现这个功能
