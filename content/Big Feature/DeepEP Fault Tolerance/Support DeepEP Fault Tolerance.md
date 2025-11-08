# 0 Base
git clone DeepEP/nvshmem，然后把deepEP下面的third-party内的nvshmem.patch的改动加到自己的nvshmem上。
## 0.1 Compile NVSHMEM
这里的-DNVSHMEM_BUILD_PYTHON_LIB=OFF一定需要设置。
```shell
CUDA_HOME=/usr/local/cuda/ && \
NVSHMEM_SHMEM_SUPPORT=0 \
NVSHMEM_UCX_SUPPORT=0 \
NVSHMEM_USE_NCCL=0 \
NVSHMEM_IBGDA_SUPPORT=1 \
NVSHMEM_PMIX_SUPPORT=0 \
NVSHMEM_MPI_SUPPORT=0 \
NVSHMEM_TIMEOUT_DEVICE_POLLING=0 \
cmake -S . -B build/  -DCUDA_ARCHITECTURES=90 -DCMAKE_VERBOSE_MAKEFILE=ON -DCMAKE_INSTALL_PREFIX=/opt/nvshmem -DNVSHMEM_BUILD_PYTHON_LIB=OFF && \
cd build
make -j$(nproc)
```
## 0.2 Compile  DeepEP
这里需要export TORCH_CUDA_ARCH_LIST="9.0" 不然会出问题。
```shell
export NVSHMEM_DIR=/opt/nvshmem
export LD_LIBRARY_PATH="${NVSHMEM_DIR}/lib:$LD_LIBRARY_PATH"
export PATH="${NVSHMEM_DIR}/bin:$PATH"
export TORCH_CUDA_ARCH_LIST="9.0"
NVSHMEM_DIR=/opt/nvshmem python setup.py build
```
# 1 Related
a. 在DeepEP的[[internode_ll.cu]]内包含了dispatch和combine，二者内使用了nvshmemi_ibgda_put_nbi_warp来通信，以及nvshmemi_ibgda_amo_nonfetch_add给remote进程加原子计数的原理。
b. DeepEP的[[ibgda_device.cuh]]内具体写了nvshmemi_ibgda_put_nbi_warp和nvshmemi_ibgda_amo_nonfetch_add的接口。
c. 具体的传输在NVSHMEM的[[ibgda.cpp]]内实现。
# 2 Specific Plan
## 2.1 nvshmem ibgda create backup QP
在 `nvshmemt_init` 函数中枚举 IB 设备后，根据网卡配置创建备份 QP 映射关系：
- **一卡一口**：相邻网卡互备（mlx5_0↔mlx5_1, mlx5_2↔mlx5_3, mlx5_4↔mlx5_5, mlx5_6↔mlx5_7）
- **一卡两口**：同一网卡的两个端口互备
### 2.1.1 扩展数据结构
在 `nvshmemt_ibgda_state_t` 结构体添加备份QP字段：
```c
typedef struct {
    int *dev_ids;
    int *port_ids;
    // ... 现有字段 ...
    
    // 备份 QP 相关字段
    int *backup_dev_ids;        // 备份设备 ID 数组
    int *backup_port_ids;       // 备份端口 ID 数组
    bool *is_single_port_card;  // 标记是否为一卡一口
} nvshmemt_ibgda_state_t;
```

### 2.1.2 实现备份映射逻辑
在 `nvshmemt_init` 函数中，设备枚举完成后，添加备份映射创建函数调用。
**新增函数 `ibgda_create_backup_mapping`**：
  1. 遍历所有已枚举的设备（`ibgda_state->n_dev_ids`）
  2. 检查每个设备的 `phys_port_cnt`：
     - 若 `== 1`：一卡一口，使用相邻配对策略（i 与 i^1 配对，即 0↔1, 2↔3, 4↔5, 6↔7）
     - 若 `== 2`：一卡两口，查找同一设备的另一端口

  3. 填充 `backup_dev_ids[]` 和 `backup_port_ids[]` 数组
  4. 对于无法找到备份的设备，记录警告日志
  
一卡一口:
```
for i in 0..n_dev_ids:
    device_id = dev_ids[i]
    device = devices[device_id]
    
    if device.phys_port_cnt == 1:
        // 相邻配对：i XOR 1
        backup_idx = i XOR 1
        if backup_idx < n_dev_ids:
            backup_dev_ids[i] = dev_ids[backup_idx]
            backup_port_ids[i] = port_ids[backup_idx]
```

一卡两口:
```
if device.phys_port_cnt == 2:
    // 查找同一设备的另一个端口
    for j in 0..n_dev_ids:
        if dev_ids[j] == device_id && port_ids[j] != port_ids[i]:
            backup_dev_ids[i] = dev_ids[j]
            backup_port_ids[i] = port_ids[j]
            break
```

### 2.1.3 分配和初始化备份数组
在 `nvshmemt_init` 中，在 `ibgda_state` 分配后：
```c
// 在 ibgda_state 字段赋值处添加
ibgda_state->backup_dev_ids = (int *)malloc(MAX_NUM_PES_PER_NODE * sizeof(int));
ibgda_state->backup_port_ids = (int *)malloc(MAX_NUM_PES_PER_NODE * sizeof(int));
ibgda_state->is_single_port_card = (bool *)malloc(MAX_NUM_PES_PER_NODE * sizeof(bool));
// 添加内存分配检查
```

### 2.1.4 调用备份映射函数

在设备枚举完成后（约行 4874 "End - Ordered list of devices" 日志后），调用：

```c
status = ibgda_create_backup_mapping(ibgda_state);
NVSHMEMI_NZ_ERROR_JMP(status, NVSHMEMX_ERROR_INTERNAL, out,
                      "Failed to create backup QP mapping.\n");
```
### 2.1.5 清理资源
在 `out:` 标签的清理代码中，添加备份数组的释放：

```c
if (ibgda_state) {
    if (ibgda_state->backup_dev_ids) free(ibgda_state->backup_dev_ids);
    if (ibgda_state->backup_port_ids) free(ibgda_state->backup_port_ids);
    if (ibgda_state->is_single_port_card) free(ibgda_state->is_single_port_card);
}
```

## 2.2 Check CQ status and checkout to backup QP


## 2.3 Checkout to normal QP