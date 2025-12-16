## 0 
在megatron的moe使能deepep后，可以看到deepep主要的四次kernel。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20251105135518984.png )
具体使用的线程数量如下：

| operations                        | kernel agrs         |
| --------------------------------- | ------------------- |
| intranode::cached_notify_dispatch | <<<1, 128>>>        |
| intranode::dispatch               | <<<20, 768, 8192>>> |
| intranode::cached_notify_combine  | <<<11, 128>>>       |
| intranode::combine                | <<<20, 768>>>       |

## 1. dispatch
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

| 变量                         | 含义                        | 计算方式                                       | 范围  |
| -------------------------- | ------------------------- | ------------------------------------------ | --- |
| sm_id                      | 当前block的index             | blockIdx.x                                 | 20  |
| warp_id                    | 一个block内warp的index        | threadIdx.x / 32                           | 24  |
| lane_id                    | warp内thread的index         | threadIdx.x % 32                           | 32  |
| warp_group_id              | warp所在的group的index        | warp_id / num_warps_per_group              | ～=8 |
| sub_warp_id                | warp在一个warp group内的index  | warp_id % num_warps_per_group              | ～=3 |
| responsible_exp<br>ert_idx | warp group负责的expert的index | sm_id * num_warp_groups<br>+ warp_group_id |     |

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
            // 跨节点: 使用 RDMA
            nvshmemi_ibgda_put_nbi_warp(dst_ptr, src_ptr, num_bytes_per_msg, dst_rank, dst_expert_local_idx, lane_id, slot_idx);
        } else {
            // 节点内: 使用 NVLink P2P 直接内存拷贝
            UNROLLED_WARP_COPY(...);
        }
        
        // 5. 完成后增加计数器
        atomic_add_release_global(atomic_finish_counter_per_expert + dst_expert_idx, 1);
    }
```
与此同时，第一个sm的最后一个warp负责清理缓冲区，其他sm上的最后一个warp内在统计当前已经发送完的数据：
```cpp
if (sm_id == 0) {
    // 1. 清理下一次迭代要用的缓冲区（行 289-290）
    for (int i = lane_id; i < num_next_clean_int; i += 32)
        next_clean[i] = 0;
    
    // 2. 初始化所有专家的完成计数器（行 294-296）
    for (int i = lane_id; i < num_experts; i += 32)
        atomic_add_release_global(atomic_finish_counter_per_expert + i, FINISHED_SUM_TAG);
}

// 每个 SM 负责统计一部分专家（expert_begin_idx 到 expert_end_idx）
int expert_count[kNumMaxWarpGroups] = {0};
const auto expert_begin_idx = sm_id * num_warp_groups;
const auto expert_end_idx = min(expert_begin_idx + num_warp_groups, num_experts);

// 遍历所有 topk_idx，统计属于本 SM 负责专家的 token 数量
for (int i = lane_id; i < num_tokens * num_topk; i += 32) {
    auto idx = static_cast<int>(__ldg(topk_idx + i));
    if (idx >= expert_begin_idx and idx < expert_end_idx)
        expert_count[idx - expert_begin_idx]++;
}

// Warp reduce 汇总并更新全局计数器
for (int i = expert_begin_idx; i < expert_end_idx; ++i) {
    auto sum = warp_reduce_sum(expert_count[i - expert_begin_idx]);
    if (lane_id == 0) {
        // 一个sm上一个share mem来存当前发的token数量
        shared_num_tokens_sent_per_expert[i - expert_begin_idx] = sum;
        // counter初始化的时候是FINISHED_SUM_TAG，这里for循环发完就是sum，所以后面的代码在用while轮询这里不同responsible_expert_idx的FINISHED_SUM_TAG + sum + FINISHED_SUM_TAG - sum是不是已经等于FINISHED_SUM_TAG * 2了
        atomic_add_release_global(atomic_finish_counter_per_expert + i, FINISHED_SUM_TAG - sum);
    }
}
```
在数据完成发送后，每个warp group的sub warp 0还要用一次ibgda，因为要告诉对端我现在数据发完了。
```cpp
auto dst_ptr = reinterpret_cast<uint64_t>(rdma_recv_count + dst_expert_local_idx * num_ranks + rank);
auto dst_p2p_ptr = nvshmemi_get_p2p_ptr(dst_ptr, rank, dst_rank);
auto num_tokens_sent = shared_num_tokens_sent_per_expert[responsible_expert_idx - sm_id * num_warp_groups];
while (ld_acquire_global(atomic_finish_counter_per_expert + responsible_expert_idx) != FINISHED_SUM_TAG * 2)
	;
if (not is_rank_masked(mask_buffer_ptr, dst_rank)) {
    if (dst_p2p_ptr == 0) {
        // RDMA 原子操作
        nvshmemi_ibgda_amo_nonfetch_add(reinterpret_cast<int*>(dst_ptr), -num_tokens_sent - 1, dst_rank, dst_expert_local_idx);
    } else {
        // P2P 本地写
        st_release_sys_global(reinterpret_cast<int*>(dst_p2p_ptr), -num_tokens_sent - 1);
    }
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

## 