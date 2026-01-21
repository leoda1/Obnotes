## 1. notify_dispatch(internode.cu)
### define
这里分为sm0用于通信同步和其他sm准备dispatch的metadata。分为下面1，2两点：
1. **==sm0：==**
* 阶段1: `nvshmemi_ibgda_quiet(dst_rdma_rank, qp_id)` 等待其他 RDMA 节点的操作完成。
* 阶段2: 机内机间同步。thread_id == 32（warp 1 的 lane 0）：执行机间同步，确保所有 RDMA 节点前面的任务结束，再去clean up掉rdma_buffer_ptr。
* 阶段3:把每个rank、expert、rdma_rank对应的token数量写到send_buffer内对应的地址上。
```cpp
send_buffer(0)[0..7]   = num_tokens_per_rank[0..7]   (8个NVL rank的token数)
send_buffer(0)[8..23]  = num_tokens_per_expert[0..15] (16个expert的token数)
send_buffer(0)[24]     = num_tokens_per_rdma_rank[0]  (RDMA rank 0总token数)
```
* 阶段4:RDMA发送，写完之后调用一次nvshmem的put操作。比如rank0的sm0的warp1发送给rank1
```cpp
本地: send_buffer(1) [25个int] 
      ↓ (RDMA PUT)
远程: recv_buffer(0) [25个int] (在rank 1的GPU上)
```
* 阶段5：机内机间同步。
* 阶段6：从所有 RDMA 节点的 recv_buffer 读取，按 expert 求和；计算前缀和，并发送给节点内其他gpu；之后接受的时候就可以全局聚合前缀和和 expert token 数。
* 阶段7:：机内机间同步。

2. **==sm1-x:==**
* 阶段1：for loop遍历所有token，根据is_token_in_rank这个router map计算出来total_count（发送到该RDMA rank的总token数）和per_nvl_rank_count[j] (发送到该 RDMA rank 的各个 NVL GPU 的 token 数)。
* 阶段2：写入 gbl_channel_prefix_matrix 和 rdma_channel_prefix_matrix
* 阶段3：为每个 channel 计算前缀和，用于后续数据分发的索引计算
```cpp
template <bool kLowLatencyMode, int kNumRDMARanks>
__global__ void notify_dispatch(...) {
    // 所有gpu的sm0来负责同步通信
    if (sm_id == 0) {
        // 阶段1
        auto qps_per_rdma_rank = ibgda_get_state()->num_rc_per_pe * ibgda_get_state()->num_devices_initialized;
        for (int i = thread_id; i < qps_per_rdma_rank * (kNumRDMARanks - 1); i += num_threads) {
            auto dst_rdma_rank = (i / qps_per_rdma_rank + rdma_rank + 1) % kNumRDMARanks;
            auto qp_id = i % qps_per_rdma_rank;
            nvshmemi_ibgda_quiet(translate_dst_rdma_rank<kLowLatencyMode>(dst_rdma_rank, nvl_rank), qp_id);
        }
        __syncthreads();
        // 阶段2
        if (thread_id == 32)
            nvshmem_sync_with_same_gpu_idx<kLowLatencyMode>(rdma_team); // 机间同步
        barrier_block<NUM_MAX_NVL_PEERS, true>(barrier_signal_ptrs, nvl_rank); // 机内同步
        // 阶段3
        for (int i = thread_id; i < num_ranks; i += num_threads)
            rdma_recv_num_tokens_mixed.send_buffer(i / NUM_MAX_NVL_PEERS)[i % NUM_MAX_NVL_PEERS] = num_tokens_per_rank[i];
        for (int i = thread_id; i < num_experts; i += num_threads)
            rdma_recv_num_tokens_mixed.send_buffer(i / num_rdma_experts)[NUM_MAX_NVL_PEERS + i % num_rdma_experts] =
                num_tokens_per_expert[i];
        if (thread_id < kNumRDMARanks)
            rdma_recv_num_tokens_mixed.send_buffer(thread_id)[NUM_MAX_NVL_PEERS + num_rdma_experts] = num_tokens_per_rdma_rank[thread_id];
        // 阶段4
        for (int i = warp_id; i < kNumRDMARanks; i += num_warps) {
            if (i != rdma_rank) {
                nvshmemi_ibgda_put_nbi_warp<true>((rdma_recv_num_tokens_mixed.recv_buffer(rdma_rank)),
                (rdma_recv_num_tokens_mixed.send_buffer(i)), i, 0, lane_id,0);
            } else {机内拷贝}
        }
        // 阶段5
        nvshmemi_ibgda_quiet(thread_id, 0); // 等RDMA 完成
        nvshmem_sync_with_same_gpu_idx<kLowLatencyMode>(rdma_team); // 机间同步
        // 阶段6
        for (int i = 0; i < kNumRDMARanks; ++i)
            sum += rdma_recv_num_tokens_mixed.recv_buffer(i)[NUM_MAX_NVL_PEERS + thread_id];
        nvl_reduced_num_tokens_per_expert[thread_id] = sum;
        for (int i = 0; i < kNumRDMARanks; ++i) {
            sum += rdma_recv_num_tokens_mixed.recv_buffer(i)[NUM_MAX_NVL_PEERS + num_rdma_experts];
            recv_rdma_rank_prefix_sum[i] = sum;
        }
        *moe_recv_rdma_counter_mapped = sum;
        for (int i = 0; i < kNumRDMARanks; ++i)
            nvl_send_num_tokens_per_rank.buffer(nvl_rank)[i] = rdma_recv_num_tokens_mixed.recv_buffer(i)[thread_id];
        for (int i = 0; i < num_nvl_experts; ++i)
            nvl_send_num_tokens_per_expert.buffer(nvl_rank)[i] = nvl_reduced_num_tokens_per_expert[thread_id * num_nvl_experts + i];
        for (int i = 0; i < num_ranks; ++i) {
            int src_rdma_rank = i / NUM_MAX_NVL_PEERS, src_nvl_rank = i % NUM_MAX_NVL_PEERS;
            sum += nvl_recv_num_tokens_per_rank.buffer(src_nvl_rank)[src_rdma_rank];
            recv_gbl_rank_prefix_sum[i] = sum;
        }
        *moe_recv_counter_mapped = sum;
        for (int i = 0; i < NUM_MAX_NVL_PEERS; ++i)
            sum += nvl_recv_num_tokens_per_expert.buffer(i)[thread_id];
        sum = (sum + expert_alignment - 1) / expert_alignment * expert_alignment;
        moe_recv_expert_counter_mapped[thread_id] = sum;
        // 阶段7
        nvshmem_sync_with_same_gpu_idx<kLowLatencyMode>(rdma_team);
        barrier_block<NUM_MAX_NVL_PEERS>(barrier_signal_ptrs, nvl_rank);
    // Calculate meta data
    } else {
        for () {
            for (int j = 0; j < NUM_MAX_NVL_PEERS; ++j)
                per_nvl_rank_count[j] += is_token_in_rank_values[j];
            total_count += (is_token_in_rank_uint64 != 0);
        }
        //...
    }
}
```
### 同步
这里主要就是nvshmemi_ibgda_quiet、nvshmem_sync_with_same_gpu_idx和barrier_block三种同步。
#### ==a. barrier_block==
在最开始buffer创建的时候buffer_ptrs[nvl_rank]对应机内每个rank的一部分内存地址就已经变成ipc/frabic handle提前给其他gpu了，所以机内gpu都可以访问这一块内存。在buffer_ptrs[nvl_rank]上还分为了数据区和信号区。
```txt
buffer_ptrs[nvl_rank] (通过IPC共享，所有GPU都能访问)
├─ num_nvl_bytes (NVLink数据缓冲区)
└─ barrier_signal_bytes (barrier信号区，8个int = 32字节)
   └─ barrier_signal_ptrs[0..7] (每个int对应一个GPU的计数)
```
每个GPU调用atomicAdd_system在自己的位置上加 1024（8 次，每个线程一次），然后调用atomicSub_system在其他 GPU 的 barrier_signal[rank] 上减 1024（8 次，每个线程一次）。之后的while（true）的 `__all_sync` 一直轮询。
```cpp
template <int kNumRanks, bool kSyncOnly = false>
__forceinline__ __device__ void barrier_block(int** barrier_signal_ptrs, int rank) {
    auto thread_id = static_cast<int>(threadIdx.x);

    // For non-sync-only cases, the memory operations by other threads in the block must be visible to the `sys` scope
    if constexpr (not kSyncOnly) {
        memory_fence();
        __syncthreads();
    }

    // Add self-ranks, sub other ranks
    if (thread_id < kNumRanks) {
        atomicAdd_system(barrier_signal_ptrs[rank] + thread_id, FINISHED_SUM_TAG);
        atomicSub_system(barrier_signal_ptrs[thread_id] + rank, FINISHED_SUM_TAG);
    }
    EP_DEVICE_ASSERT(kNumRanks <= blockDim.x);

    // Check timeout
    auto start_time = clock64();
    while (true) {
        auto value = thread_id < kNumRanks ? ld_volatile_global(barrier_signal_ptrs[rank] + thread_id) : 0;
        if (__all_sync(0xffffffff, value <= 0))
            break;

        if (clock64() - start_time > NUM_TIMEOUT_CYCLES and thread_id < kNumRanks) {
            printf("DeepEP timeout check failed: rank = %d, thread = %d, value = %d)\n", rank, thread_id, value);
            trap();
        }
    }
    __syncthreads();
}
```

## 2. cached_notify(internode.cu)



## 3. dispatch(internode.cu)


