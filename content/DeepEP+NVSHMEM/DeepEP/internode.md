## 0 profile
在megatron的moe使能deepep后，可以看到deepep主要的四次kernel（在internode.cu内）。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20251105135518984.png )
具体使用的线程数量如下：

| operations                        | kernel agrs         |
| --------------------------------- | ------------------- |
| intranode::cached_notify_dispatch | <<<1, 128>>>        |
| intranode::dispatch               | <<<20, 768, 8192>>> |
| intranode::cached_notify_combine  | <<<11, 128>>>       |
| intranode::combine                | <<<20, 768>>>       |

## 1. dispatch (internode_ll.cu)
dispatch kernel 负责MoE的输入tokens根据top-k路由结果分发到不同expert ranks，**并接收来自其他ranks发过来的tokens**。
```cpp
template <bool kUseFP8, bool kUseUE8M0, int kHidden>
__global__ __launch_bounds__(1024, 1) void dispatch(
	...
)
```
通过变量phases来控制dispatch是发阶段还是收阶段还是双阶段。
```cpp
// Sending phase
if ((phases & LOW_LATENCY_SEND_PHASE) == 0)
    goto LOW_LATENCY_DISPATCH_RECV;
// ... 发送逻辑 ...

LOW_LATENCY_DISPATCH_RECV:
if ((phases & LOW_LATENCY_RECV_PHASE) == 0)
    return;
// ... 接收逻辑 ...
```
### 1.1 warp 分工策略
发送逻辑内：
```cpp
if (warp_id < num_warps - 1) {
    // 前 N-1 个 warps: 负责 FP8 转换和 RDMA 发送
    // 每个 warp 处理某些 tokens
} else if (warp_id == num_warps - 1) {
    // 最后一个 warp: 统计每个 expert 的 token 数量
    // 并负责清理下一个 buffer
}
```
接收逻辑内：
```cpp
const auto responsible_expert_idx = sm_id * num_warp_groups + warp_group_id;
// 每个 SM 的 warp group 负责特定的 local experts
// sub_warp_id == 1: 等待并统计接收的 tokens
// sub_warp_id == 0: 复制 token 数据
```
### 1.2 发送流程
假设现在就是intranode::dispatch<<<20, 768, null, null>>>的case。在发送前还需要提前算好很多索引才能让所有的线程按照warp划分后来执行。

| 变量                         | 含义                        | 计算方式                                                 | 范围   |
| -------------------------- | ------------------------- | ---------------------------------------------------- | ---- |
| sm_id                      | 当前block的index             | blockIdx.x                                           | 20   |
| warp_id                    | 一个block内warp的index        | threadIdx.x / 32                                     | 24   |
| lane_id                    | warp内thread的index         | threadIdx.x % 32                                     | 32   |
| warp_group_id              | warp所在的group的index        | warp_id / num_warps_per_group                        | ～=8  |
| sub_warp_id                | warp在一个warp group内的index  | warp_id % num_warps_per_group                        | ～=3  |
| responsible_exp<br>ert_idx | warp group负责的expert的index | sm_id * num_warp_groups<br>+ warp_group_id           | 小于32 |
| expert_begin_idx           | 每个sm开始负责的expert索引         | sm_id * num_warp_groups;<br>                         |      |
| expert_end_idx             | 每个sm结束负责的expert索引         | min(expert_begin_idx + num_warp_groups, num_experts) |      |
在前num_warps - 1个warp计算完后会调用nvshmem封装的ibgda的传输数据的接口，见[[DeepEP+NVSHMEM/DeepEP/ibgda_device.cuh]] 内的说明。传输前准备了几个参数：
* `dst_expert_idx`：在不同warp执行代码的时候会去读该 token 的第 `warp_id` 个 topk 值，作为 `dst_expert_idx`
* `slots_idx`: 每个warp的第一个线程计算`atomic_counter_per_expert + dst_expert_idx`然后`_shfl_sync`来广播给warp内其他31个线程。slots idx就是本次发送消息给专家x的某个槽
* `dst_ptr`：这个 token 对应的消息，落在对方 rank 的“第几个 expert 的 buffer 里的第几个 slot 上”的地址偏移，逻辑上就是`rdma_recv_x[expert_local_idx][src_rank][slot_idx]`这个三维地址（nvshmem的对称内存有个相同的base）转成一维的地址。
完成传输后增加atomic_finish_counter_per_expert数。
```cpp
LOW_LATENCY_DISPATCH_SEND:
    for (int token_idx = sm_id; token_idx < num_tokens; token_idx += num_sms) {
        for (int i = thread_id; i < hidden_bf16_int4; i += num_threads) {
    	    // 1. FP8 量化（如果启用）
    	    if constexpr (kUseFP8) {
    	        // 按 128 通道计算 amax
    	        // 计算 scale 和 scale_inv
    	        // 将 BF16 转换为 FP8
    	    }
    	}
        
        // 2. 根据 topk_idx 确定目标 expert 和 rank
        auto dst_expert_idx = topk_idx + token_idx * num_topk + warp_id;
        auto dst_rank = dst_expert_idx / num_local_experts;
        
        // 3. 原子获取目标 buffer 的槽位
        int slot_idx = lane_id == 0 ? atomicAdd(atomic_counter_per_expert + dst_expert_idx, 1);
        slot_idx = __shfl_sync(0xffffffff, slot_idx, 0);
        const auto dst_rank = dst_expert_idx / num_local_experts;
        const auto dst_expert_local_idx = dst_expert_idx % num_local_experts;
        const auto src_ptr = reinterpret_cast<uint64_t>(rdma_x_src_idx);
        const auto dst_ptr = reinterpret_cast<uint64_t>(rdma_recv_x) 
                        + dst_expert_local_idx * num_ranks * num_max_dispatch_tokens_per_rank * num_bytes_per_msg //对端进程的第dst_expert_local_idx个专家的块
                        + rank * num_max_dispatch_tokens_per_rank * num_bytes_per_msg //在该专家块内，按源 rank（也就是当前发送者的 rank）划分子块，保证来自不同源 rank 的数据互不冲突。
                        + slot_idx * num_bytes_per_msg; //这个 rank 下排入第几个 token 位
        const auto dst_p2p_ptr = nvshmemi_get_p2p_ptr(dst_ptr, rank, dst_rank);
        // 4. 发送数据（RDMA 或 P2P）
        if (dst_p2p_ptr == 0) {
            sm_id == 0 ? printf("[1]sm_id run into put_nbi == 0\n") : 0;
            nvshmemi_ibgda_put_nbi_warp<true>(dst_ptr, src_ptr, num_bytes_per_msg, dst_rank, dst_expert_local_idx, lane_id, slot_idx);
        } else {
            // NOTES: only 2 load iterations for 7K hidden with 8 unrolls
            const auto* src_int4_ptr = reinterpret_cast<const int4*>(src_ptr);
            const auto* dst_int4_ptr = reinterpret_cast<int4*>(dst_p2p_ptr);
            UNROLLED_WARP_COPY(8, lane_id, num_int4_per_msg, dst_int4_ptr, src_int4_ptr, ld_nc_global, st_na_global);
            sm_id == 0 ? printf("[2]sm_id run into nvlink == 0\n") : 0;
        }
        
        // 5. 完成后增加计数器
        atomic_add_release_global(atomic_finish_counter_per_expert + dst_expert_idx, 1);
    }
```
与此同时，第一个sm的最后一个warp负责清理缓冲区，其他sm上的最后一个warp内在统计当前已经发送完的数据，
```cpp
} else if (warp_id == num_warps - 1) {
        EP_DEVICE_ASSERT(num_sms > 1);
        if (sm_id == 0) {
            // The first SM is also responsible for checking QPs
            EP_DEVICE_ASSERT(ibgda_get_state()->num_rc_per_pe >= num_local_experts);

            // The first SM is also responsible for cleaning the next buffer
            #pragma unroll
            for (int i = lane_id; i < num_next_clean_int; i += 32)
                next_clean[i] = 0;

            // Notify before executing `int_p`
            __syncwarp();
            #pragma unroll
            for (int i = lane_id; i < num_experts; i += 32) {
                // lane_id == 0 and sm_id == 0 ? printf("code run into last warp_id\n") : 0; 会走
                atomic_add_release_global(atomic_finish_counter_per_expert + i, FINISHED_SUM_TAG);
            }
        }

        // This SM should be responsible for some destination experts, read `topk_idx` for them
        int expert_count[kNumMaxWarpGroups] = {0};
        const auto expert_begin_idx = sm_id * num_warp_groups;
        const auto expert_end_idx = min(expert_begin_idx + num_warp_groups, num_experts);

        // Per lane count
        #pragma unroll 8
        for (int i = lane_id; i < num_tokens * num_topk; i += 32) {
            auto idx = static_cast<int>(__ldg(topk_idx + i));
            if (idx >= expert_begin_idx and idx < expert_end_idx)
                expert_count[idx - expert_begin_idx]++;
        }

        // Warp reduce
        #pragma unroll
        for (int i = expert_begin_idx; i < expert_end_idx; ++i) {
            auto sum = warp_reduce_sum(expert_count[i - expert_begin_idx]);
            if (lane_id == 0) {
                shared_num_tokens_sent_per_expert[i - expert_begin_idx] = sum;
                atomic_add_release_global(atomic_finish_counter_per_expert + i, FINISHED_SUM_TAG - sum);
            }
        }
    }
```
在数据完成发送后，每个warp group的sub warp 0还要用一次ibgda，因为要告诉对端我现在数据发完了。
```cpp
if (responsible_expert_idx < num_experts and sub_warp_id == 0 and lane_id == 0) {
        const auto dst_rank = responsible_expert_idx / num_local_experts;
        const auto dst_expert_local_idx = responsible_expert_idx % num_local_experts;
        const auto num_tokens_sent = shared_num_tokens_sent_per_expert[responsible_expert_idx - sm_id * num_warp_groups];

        // Wait local sends issued and send expert counts
        while (ld_acquire_global(atomic_finish_counter_per_expert + responsible_expert_idx) != FINISHED_SUM_TAG * 2)
            ;
        auto dst_ptr = reinterpret_cast<uint64_t>(rdma_recv_count + dst_expert_local_idx * num_ranks + rank);
        auto dst_p2p_ptr = nvshmemi_get_p2p_ptr(dst_ptr, rank, dst_rank);
        if (not is_rank_masked(mask_buffer_ptr, dst_rank)) {
            if (dst_p2p_ptr == 0) {
                sm_id == 0 ? printf("[3]sm_id0 run into amo ope\n") : 0;
                nvshmemi_ibgda_amo_nonfetch_add(reinterpret_cast<int*>(dst_ptr), -num_tokens_sent - 1, dst_rank, dst_expert_local_idx);
            } else {
                st_release_sys_global(reinterpret_cast<int*>(dst_p2p_ptr), -num_tokens_sent - 1);
                sm_id == 0 ? printf("[4]sm_id0 not run into amo ope\n") : 0;
            }
        }

        // Clean workspace for next use
        atomic_counter_per_expert[responsible_expert_idx] = 0;
        atomic_finish_counter_per_expert[responsible_expert_idx] = 0;

        // Clean `packed_recv_count`
        if (dst_rank == 0)
            packed_recv_count[dst_expert_local_idx] = 0;
    }
```
这里发送的是 -num_tokens_sent - 1 ，接收端的 rdma_recv_count 初始化为 0，会在读取时把这个数字转为正数。
### 1.3 接收流程
每个sm上的warp group 1的第一个线程负责等待数据，数据到了每个warp group内的所有线程就会来复制数据。
```cpp
LOW_LATENCY_DISPATCH_RECV:
    // Sub-warp 1: 等待数据到达
    if (sub_warp_id == 1 and lane_id == 0) {
        // 轮询等待 rdma_recv_count 变为非零（负数）
        while ((num_recv_tokens = ld_acquire_sys_global(
                    rdma_recv_count + local_expert_idx * num_ranks + src_rank)) == 0
               && wait_cost <= NUM_TIMEOUT_CYCLES);
        
        // 超时处理：mask 掉故障节点
        if (wait_recv_cost > NUM_TIMEOUT_CYCLES) {
            atomicExch(mask_buffer_ptr + src_rank, 1);
        }
        
        // 解码 token 数量
        num_recv_tokens = -num_recv_tokens - 1;
        
        // 原子获取写入位置
        recv_token_begin_idx = atomicAdd(packed_recv_count + local_expert_idx, num_recv_tokens);
    }
    
    // 所有 sub-warps: 复制 token 数据
    for (int i = sub_warp_id; i < num_recv_tokens; i += num_warps_per_group) {
        // 复制 source info
        // 复制 hidden states（BF16 或 FP8）
        // 复制 FP8 scales（如果启用）
    }
```
### 1.4 量化策略
这个是send阶段会做的事，如果量化了，除了FP8的数据传输，还得把这里的scale也传走。
```cpp
// 按 128 通道分组量化
constexpr int kNumPerChannels = 128;

// 计算局部 amax
for (int j = 0; j < kNumElemsPerRead; ++j) {
    fp32_values[j] = static_cast<float>(bf16_values[j]);
    amax = fmaxf(amax, fabsf(fp32_values[j]));
}

// Warp 内 reduce（每 16 lanes 一组）
amax = warp_reduce_max<16>(amax);

// 计算 scale
calculate_fp8_scales(amax, scale, scale_inv, round_scale);

// 转换为 FP8 E4M3
float2 fp32x2 = {fp32_values[j] * scale, fp32_values[j + 1] * scale};
fp8x2_values[j / 2] = __nv_cvt_float2_to_fp8x2(fp32x2, __NV_SATFINITE, __NV_E4M3);
```
### 1.5 补充
#### **关于dispatch的grid dim && block dim**
在launch.cuh内可以看到`cudaLaunchConfig_t cfg = {(num_sms), (num_threads), 0, stream, nullptr, 0};`定义。在dispatch的host侧函数计算这两个值:
```cpp
// 计算grid和block的数量的公式如下：
const int num_warp_groups = ceil_div(num_experts, num_device_sms);
const int num_warps_per_group = 32 / num_warp_groups;
const auto num_warps = num_warp_groups * num_warps_per_group;
const auto num_sms = ceil_div(num_experts, num_warp_groups);

SETUP_LAUNCH_CONFIG(num_sms, num_warps * 32, stream);
```
#### 原子操作（dispatch）实现多线程正确读写的细节
dispatch内包括`atomicAdd`、 `atomic_add_release_global`、`nvshmemi_ibgda_amo_nonfetch_add`、`ld_acquire_sys_global`和`atomicExch`。
a. atomicAdd
在发端/收端都可能存在多个线程给一个expert传数据，防止覆盖。例如，收端分配接收的slot用：
```cpp
recv_token_begin_idx = atomicAdd(packed_recv_count + local_expert_idx, num_recv_tokens);
```
就可以在数组packed_recv_count[local_expert_idx]原子加上num_recv_tokens，准确的为接收到的token分配连续的slots。

b. atomic_add_release_global和ld_acquire_global
atomic_add_release_global定义：这个是ptx的`atom.add.release.gpu.global` 指令，对gpu的全局内存的ptr地址原子的加上value，这次写操作之前的所有内存操作对acquire可见。
ld_acquire_global定义：读取之前 release 操作写入的值，与release配对形成同步点。
```cpp
__device__ __forceinline__ int atomic_add_release_global(const int* ptr, int value) {
    int ret;
    asm volatile("atom.add.release.gpu.global.s32 %0, [%1], %2;" : "=r"(ret) : "l"(ptr), "r"(value));
    return ret;
}

__device__ __forceinline__ int ld_acquire_global(const int* ptr) {
    int ret;
    asm volatile("ld.acquire.gpu.global.s32 %0, [%1];" : "=r"(ret) : "l"(ptr));
    return ret;
}
```

<mark style="background: #FF5582A6;">调用点1:</mark>（在nvshmemi_ibgda_put_nbi_warp之后）
这里的粒度是block级别的，所以是记录的token粒度。一个token完成了wr的准备和doorbell后，这里就会在atomic_finish_counter_per_expert[expert]位置原子加1。
```cpp
lane_id == 0 ? atomic_add_release_global(atomc_finish_counter_per_expert + dst_expert_idx, 1) : 0;
```
<mark style="background: #FF5582A6;">调用点2：</mark>（最后一个warp初始化的时候）
给数组atomic_finish_counter_per_expert[i]的每个expert初始化为FINISHED_SUM_TAG(这个宏是1024)。
```cpp
#pragma unroll
for (int i = lane_id; i < num_experts; i += 32)
    atomic_add_release_global(atomic_finish_counter_per_expert + i, FINISHED_SUM_TAG);
```
<mark style="background: #FF5582A6;">调用电3:</mark>（最后一个warp统计时候）
计算出预期的sum后对每个数组atomic_finish_counter_per_expert[i]的expert原子加上FINISHED_SUM_TAG - sum。
```cpp
#pragma unroll
for (int i = expert_begin_idx; i < expert_end_idx; ++i) {
    auto sum = warp_reduce_sum(expert_count[i - expert_begin_idx]);
    if (lane_id == 0) {
        shared_num_tokens_sent_per_expert[i - expert_begin_idx] = sum;
        atomic_add_release_global(atomic_finish_counter_per_expert + i, FINISHED_SUM_TAG - sum);
    }
}
```
总的来看，调用点顺序为2->1->3。具体流程如下：
1. 每个专家的atomic_finish_counter_per_expert初始原子token数初始化为FINISHED_SUM_TAG(1024)。(所有sm的warp都可以访问)
2. warp_id < num_warps - 1：每完成一次nvshmemi_ibgda_put_nbi_warp就会在数组atomic_finish_counter_per_expert对应的专家位置+1。(注：moe的每个token需要发给topk个专家，这里传进dispatch的topk_idx是一维数组，里面总数就是token总数乘以topk，存好了token[i]发送给哪个expert。发送阶段每个sm内的warp_id在这个数组上去找自己token发给哪个专家，如下：
    `dst_expert_idx = warp_id < num_topk ? __ldg(topk_idx + token_idx * num_topk + warp_id)) : -1`
3. 每个 SM 的最后一个 warp 的 lane 0 : 在统计的时刻，单个sm内，用shared memory数组存了该sm负责的某些专家的token的总数。atomic_finish_counter_per_expert数组的专家i位置再加上 FINISHED_SUM_TAG - sum (注：**这个sum是不是真实的**，是提前计算出来要收到的数量。第二步里面的topk_idx总长是num_tokens * num_topk，所以deepep去for loop了整个一位数组，算出来每个对应的专家要收几个tokens
    ```cpp
    #pragma unroll 8
        for (int i = lane_id; i < num_tokens * num_topk; i += 32) {
            auto idx = static_cast<int>(__ldg(topk_idx + i));
            if (idx >= expert_begin_idx and idx < expert_end_idx)
                expert_count[idx - expert_begin_idx]++;
        }
    // Warp reduce
    #pragma unroll
    for (int i = expert_begin_idx; i < expert_end_idx; ++i) {
        auto sum = warp_reduce_sum(expert_count[i - expert_begin_idx]);
        if (lane_id == 0) {
            shared_num_tokens_sent_per_expert[i - expert_begin_idx] = sum;
            atomic_add_release_global(atomic_finish_counter_per_expert + i, FINISHED_SUM_TAG - sum);
        }
    }
    ```
    接着对这个warp内的32个lane线程reduce求和拿到当前这个sm对目标专家i预期要发送的token数量（就是这个sum，需要记住这是预先计算出来的，不是真实传输的）。
4. 接着一直死轮询对应的专家的原子数有没有变成FINISHED_SUM_TAG * 2，因为当nvshmemi_ibgda_put_nbi_warp对目标专家完成一次token的put操作就会+1，在 syncthreads(); 之后专家i要收到的token就是步骤三里面算的sum个，正好抵消。FINISHED_SUM_TAG + sum + (FINISHED_SUM_TAG - sum)；（其实就是实际下的wr和预期要收的wr数量一致）
```cpp
// 
while (ld_acquire_global(atomic_finish_counter_per_expert + responsible_expert_idx) != FINISHED_SUM_TAG * 2)
    ;
```
5. 当上面while完成就会去下amo，此时又用了第三步的shared_num_tokens_sent_per_expert(sm上的shared_memory)，之前是每个sm的最后一个warp来往这个里面写入发给某个专家的token总数，现在每个sm内其他0到n-2个warp来共享内存读取这个值。这个value会变成wqe发给对端。


c. ld_acquire_sys_global
 定义：读之前release写入到sys.global内的值，这是系统级别全局内存可见(跨GPU和跨节点)。
```cpp
__device__ __forceinline__ uint64_t ld_acquire_sys_global(const uint64_t* ptr) {
    uint64_t ret;
    asm volatile("ld.acquire.sys.global.u64 %0, [%1];" : "=l"(ret) : "l"(ptr));
    return ret;
}
```
在dispatch的receiver会去调用 ld_acquire_sys_global检查地址 `rdma_recv_count + local_expert_idx * num_ranks + src_rank` 的value有没有变。为什么这里的`rdma_recv_count` 可以跨GPU/节点访问? 因为这是一个nvshmem_align（NVSHMEM的对称内存分配）的，由上层deep_ep_cpp.Buffer()实例化的时候自己的初始化内会去调用 `nvshmem_align(alignment, size)` 。
这个偏移下两个跨机的rank内：
```cpp
Rank 0 的视角:
  rdma_recv_count[0 * num_ranks + 0] = 从 rank 0 发送到 expert 0 的 count（本地）
  rdma_recv_count[0 * num_ranks + 1] = 从 rank 1 发送到 expert 0 的 count（远程）
  rdma_recv_count[0 * num_ranks + 2] = 从 rank 2 发送到 expert 0 的 count（远程）

Rank 1 的视角（相同的虚拟地址）:
  rdma_recv_count[0 * num_ranks + 0] = 从 rank 0 发送到 expert 0 的 count（远程）
  rdma_recv_count[0 * num_ranks + 1] = 从 rank 1 发送到 expert 0 的 count（本地）
  rdma_recv_count[0 * num_ranks + 2] = 从 rank 2 发送到 expert 0 的 count（远程）
```

**额外知识：**
python绑定c++：
```cpp
// deep_ep.hpp
namespace deep_ep {
    struct Buffer { ... };
    struct Config { ... };
    struct EventHandle { ... };
}

// deep_ep.cpp
namespace deep_ep {
    // Buffer 的实现
    void Buffer::sync(...) {
        ...
        nvshmem_align(alignment, size);
    }
}

// pybind11 绑定
PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
    pybind11::class_<deep_ep::Buffer>(m, "Buffer")  // 使用完全限定名
        .def(pybind11::init<...>())
        .def("sync", &deep_ep::Buffer::sync);
}
```
然后对python的Buffer类初始化init内调用这个前面绑定的c++的sync：
```python
class Buffer:
    def __init__(self,
                 group: Optional[dist.ProcessGroup],
                 num_nvl_bytes: int = 0,
                 num_rdma_bytes: int = 0,
                 low_latency_mode: bool = False,
                 ...
                 comm: Optional["mpi4py.MPI.Comm"] = None) -> None:
        ...
        self.runtime.sync(device_ids, ipc_handles, root_unique_id)
```




最后用ld_acquire_global去访问这个原子有没有变成2048来判断

## 