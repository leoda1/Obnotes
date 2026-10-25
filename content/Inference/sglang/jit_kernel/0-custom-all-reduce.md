# 调用

在镜像内跑完，证明 ar 是可以正常跑的，所以注册，同步，ptx 三大类功能是没问题的
1. kMaxNumGPU支持 16
2. THRESHOLD_2_SHOT_MAP支持 16
3. torchrun --nproc_per_node=16 jit_kernel/tests/test_custom_all_reduce.py
```
root@dsw-896084-5887cf5476-wt6ng:/usr/local/lib/python3.12/site-packages/sglang# python -m pytest "jit_kernel/tests/test_custom_all_reduce.py::test_custom_allreduce[8]" -v
========================================================================================== test session starts ===========================================================================================
platform linux -- Python 3.12.3, pytest-7.2.0, pluggy-1.3.0 -- /usr/local/bin/python
cachedir: .pytest_cache
hypothesis profile 'default' -> database=DirectoryBasedExampleDatabase(PosixPath('/usr/local/lib/python3.12/site-packages/sglang/.hypothesis/examples'))
rootdir: /usr/local/lib/python3.12/site-packages/sglang
plugins: anyio-4.3.0, xdist-3.6.1, hypothesis-6.103.4
collected 1 item                                                                                                                                                                                         

jit_kernel/tests/test_custom_all_reduce.py::test_custom_allreduce[8] 
PASSED

root@dsw-896084-5887cf5476-wt6ng:/usr/local/lib/python3.12/site-packages/sglang# torchrun --nproc_per_node=16 jit_kernel/tests/test_custom_all_reduce.py
W1010 11:42:48.014000 173337 site-packages/torch/distributed/run.py:852] 
W1010 11:42:48.014000 173337 site-packages/torch/distributed/run.py:852] *****************************************
W1010 11:42:48.014000 173337 site-packages/torch/distributed/run.py:852] Setting OMP_NUM_THREADS environment variable for each process to be 1 in default, to avoid your system being overloaded, please further tune the variable for optimal performance in your application as needed. 
W1010 11:42:48.014000 173337 site-packages/torch/distributed/run.py:852] *****************************************
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
sglang_fl platform activating: vendor=thead, device=cuda
PlatformFL initialized: vendor=thead, device=cuda, dist_backend=nccl, count=16
[Gloo] Rank 0 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 4 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 1[Gloo] Rank  is connected to 15 peer ranks. Expected number of connected peer ranks is : 153
 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 2 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 5 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 9 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank [Gloo] Rank 710 is connected to  is connected to 1515 peer ranks.  peer ranks. Expected number of connected peer ranks is : Expected number of connected peer ranks is : 1515

[Gloo] Rank 12 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 14 is connected to [Gloo] Rank 15 peer ranks. Expected number of connected peer ranks is : 1315 is connected to 
15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 6 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 8 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 11 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 15 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 9 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 12 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 4 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 2 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 1 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 6 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 10 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 11 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 0 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 15 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank [Gloo] Rank 3 is connected to 1514 peer ranks.  is connected to Expected number of connected peer ranks is : 1515 peer ranks. 
Expected number of connected peer ranks is : 15
[Gloo] Rank 5 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 8 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 7 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[Gloo] Rank 13 is connected to 15 peer ranks. Expected number of connected peer ranks is : 15
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:42:59] INFO custom_all_reduce_utils.py:326: reading GPU P2P access cache from /root/.cache/sglang/gpu_p2p_access_cache_for_0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15.json
[2026-10-10 11:43:00] INFO common.py:3045: Custom allreduce v2 initialized successfully (rank-check failed: tensor model parallel group is not initialized)
dsw-896084-5887cf5476-wt6ng accl-lite version: v1.1.161.g2ce54ae
dsw-896084-5887cf5476-wt6ng accl-lite version: v1.1.161.g2ce54ae
dsw-896084-5887cf5476-wt6ng accl-lite version: v1.1.161.g2ce54ae
dsw-896084-5887cf5476-wt6ng accl-lite version: v1.1.161.g2ce54ae
```

# 实现

主要包括：one-shot pull、one-shot push、two-shot pull 三类 ar 的算法。

单看计算,one-shot 的核心就是 `all_reduce_impl`(pull.cuh:41-69)加 `reduce_impl`(cuh:331-352)。外面的 kernel 壳(pull.cuh:72-89)只负责前后两次跨卡同步,保证读的时候数据已就绪、读完别人才能复用 buffer。

下面按执行顺序走一遍,以 bf16 为例。

## 1. 一次处理多大一块

```cpp
constexpr uint32_t kVecSize = 16 / (sizeof(DType) * 2);   // pull.cuh:45
using DType2  = packed_t<DType>;                           // bf16 -> bf16x2_t
using Storage = AlignedVector<DType2, kVecSize>;
```

- bf16 的 `sizeof` 是 2,所以 `kVecSize = 4`。
- `DType2` 是 bf16x2,把 2 个 bf16 打包进 4 字节(type.cuh:67)。
- `Storage` 是 4 个 bf16x2,共 16 字节,即 8 个 bf16。
- fp32 时 `kVecSize = 2`,`Storage` 是 2 个 float2,也是 16 字节。

所以每个线程每次迭代处理 16 字节,对应一条 128-bit 的 load/store,这是 GPU 单线程最宽的访存指令。`AlignedVector::load` 的实现是 `reinterpret_cast<storage_t*>(ptr)[offset]`(vec.cuh:85-87),`offset` 的单位是"第几个 16 字节块"。

## 2. 线程怎么分活(pull.cuh:50-52)

```cpp
for (auto i = blockIdx.x;; i += gridDim.x) {
  const auto offset = i * blockDim.x + threadIdx.x;
  if (offset * kVecSize * 2 >= num_items) break;
```

这是 grid-stride 循环。
- 把数据切成"每块 `blockDim.x` 个 16 字节"的段,block `b` 先处理第 `b` 段。
- 处理完后跳 `gridDim.x` 段,继续处理下一段,直到越界。
- 同一个 block 里相邻线程读相邻 16 字节,访存是合并的。
- `offset * kVecSize * 2` 把"第几个向量"换算成元素下标(`kVecSize` 个 pack、每个 pack 2 个元素),和 `num_items`(元素总数)比较。

一个值得注意的点:越界判断是按整个向量算的。如果 `numel` 不是 8 的倍数(bf16),最后一个向量会多读几个元素。pull.cuh 里我只看到 16 字节对齐的检查(pull.cuh:164),没看到对 `numel` 整除性的检查。two-shot 的注释写了 "must be divisible here"(pull.cuh:107),调用方可能保证了这一点,但我没有去核实。

## 3. 从所有 GPU 读(pull.cuh:53-58)

```cpp
Storage storage[kNumGPU];
#pragma unroll
for (uint32_t i = 0; i < kNumGPU; ++i)
  storage[i].load(input[i], offset);
```

`input[i]` 是 GPU i 上那块数据在本进程里的地址。对端的那份是通过 IPC 映射进来的(前面讲 `register_inputs` 时看到的)。所以 `load(input[i], ...)` 是一次直接的远端读,走 NVLink 或 PCIe,没有任何通信库调用。

`#pragma unroll` 把循环展开后,编译器会把 N 条 load 一起发出去,再统一等结果。N 个远端读同时在飞,可以掩盖远端访存的高延迟。这个 kernel 的瓶颈是带宽和延迟,算术量可以忽略。

## 4. 求和(`reduce_impl`)

```cpp
fp32x2_t acc[N] = {};                               // N = kVecSize = 4, 每个是 float2
for i in 0..M:                                      // M = kNumGPU
  for j in 0..N:
    const auto [x, y] = cast<fp32x2_t>(storage[i][j]);   // bf16x2 -> float32x2
    acc[j].x += x;  acc[j].y += y;
result[j] = cast<DType2>(acc[j]);                   // float2 -> bf16x2
```

先搞清类型:`storage[i][j]` 是一个 bf16x2,也就是 2 个 bf16。`cast<fp32x2_t>` 走 `dtype_trait<fp32x2_t>::from`,对应 `__bfloat1622float2`(type.cuh:72)。回写时对应 `__float22bfloat162_rn`(type.cuh:78),`_rn` 是就近舍入。

计算原理(大白话):先全部转成 fp32 加完,最后只舍入一次。

bf16 只有 8 位有效数字。要是每加一张卡就用 bf16 存一次,每步都丢一点精度,8 张卡累积下来误差会很明显。这就像算账,用计算器把所有金额加完再四舍五入一次,而不是每加一笔就四舍五入。

`float2` 配合 bf16x2 是因为硬件转换指令一次处理一对,代码里一次转换两个元素。

还有一点不显眼的细节:加法顺序固定,`i` 从 0 到 M-1,对应的是 GPU 编号。浮点加法不满足结合律,顺序不同结果可能差几个 ulp。one-shot 里每个 rank 都独立把整份数据算一遍,如果顺序不一致,各卡的结果就会有细微差异。这里 `input[i]` 的下标是 GPU 编号,每个 rank 看到的顺序相同,所以所有 rank 的结果逐位一致。我是从代码推出这一点的,没有跑实验验证。

## 5. 写回

`kBroadcast=false` 时走 `result.store(output, offset)`(pull.cuh:66),只写本卡的 output。

非 graph 路径下,pull.cuh:152 让 `output = input`,看起来像原地写回。它之所以安全,是因为 kernel 读的是前面 `cudaMemcpyAsync` 拷进去的 pull buffer(pull.cuh:187),而写的是原 input tensor,两者不是同一块内存。graph 路径没有这个拷贝,直接读各卡真实的 input,所以必须另分配 `empty_like(input)` 当输出,避免写了别人还没读完的数据。

## 6. 两次同步各管什么

- 开头 `ctrl.sync<0,1>`(pull.cuh:84):等所有卡都把数据准备好(拷进 buffer 或 graph 里上游 kernel 写完),再开始读。
- 结尾 `ctrl.sync<0,0>`(pull.cuh:88):等所有卡都读完我的数据,我的 buffer 才能在下一次调用被覆盖。

## 流程图

```
每个 rank、每个 block、每个线程(grid-stride):
 offset = i*blockDim + tid        // 第几个 16B 块
   │
   ├─ load(input[0], offset) ┐
   ├─ load(input[1], offset) │ N 条 128-bit 远端读, 展开后同时发出
   ├─ ...                    │ (input[k] = GPU k 的数据地址, IPC 映射)
   └─ load(input[N-1],offset)┘
   │
   ▼ reduce_impl
 每个 bf16x2 ─▶ float2  ─┐
 acc[j] += (按 GPU 0..N-1 固定顺序)
 acc[j] ─▶ bf16x2 (一次就近舍入)
   │
   ▼
 store(output, offset)   // 128-bit 本地写
```
