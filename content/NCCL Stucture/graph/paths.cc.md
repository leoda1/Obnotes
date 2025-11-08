


## PXN
环境变量是（默认会打开）:
```cpp
NCCL_PARAM(PxnDisable, "PXN_DISABLE", 0);
```
### PXN的topo判断逻辑
* 需要确保PCI连接到NIC
* 需要确保NVLink连接到目标GPU
* 需要确保在同一节点
* 需要确保更高带宽到NIC
* 需要确保避免通过CPU
```cpp
ncclResult_t ncclTopoComputePaths(...) {
  ...
  if (peerNode->paths[NET][n].type <= PATH_PXB && // Is connected to the NIC through PCI
    peerNode->paths[GPU][g].type <= PATH_NVL && // Is connected to us through NVLink
    NCCL_TOPO_ID_SYSTEM_ID(peerNode->id) == NCCL_TOPO_ID_SYSTEM_ID(gpu->id) && // Is on the same node as us
    (peerNode->paths[NET][n].bw > gpu->paths[NET][n].bw || // Has either higher BW to that NIC
    gpu->paths[NET][n].type > PATH_PXB))
  ...
}
```
