# 0 nccl issue

https://github.com/NVIDIA/nccl/issues/919
https://github.com/NVIDIA/nccl/issues/1725 （CollNet + SHARP和NVLS的diff）
CollNet + SHARP是interNode考虑的，需要Mellanox交换机去reduction。
NVLS(NVLink SHARP)是hopper intraNode考虑的，8 GPUs reduction。在blackwell之后会是72 GPUs reduction。后面这个叫MNVL(multi-node NVLink, systems);
https://github.com/NVIDIA/nccl/issues/320 （什么是CollNet）

# 1 介绍

# 2 代码实现
host侧调用顺序
1. collectives.cc(ncclAllReduce)
2. enqueue.cc(任务入队/规划)
3. 选择算法（含 NVLS/对称内核)，这里附带了特定 Fn/Algo/Proto/Type/RedOp 的内核符号
4. 准备连接/缓冲（nvls.cc）
5. 启动 CUDA 内核。
先跳过前三点，进入4-5。
## 2.1 nvls.cc
NVSwitch的multicast创建、内存映射、缓冲区分配和注册等都在transport/nvls.cc。[[nvls.cc]]
## 2.2 device侧调用
在all_reduce.h内的device侧对NVLS的实现如下：
![[NVLS && NVLS Tree AllRuduce 2025-10-07 23.53.26.excalidraw | 100%]]

## 2.3 NVSwitch SHARP 计算
Symmetric 内核里通过 “multimem” 指令在 NVSwitch 侧完成跨 GPU 的 reduce。[[all_reduce.cuh]]