## 0. 整体架构
Token Dispatcher 是 MoE 中负责 token 分发与合并的组件。
```txt
MoELayer (MoE 层)
    └──> Token Dispatcher (token 分发器)
            ├── Dispatch 流程（发送 tokens 到专家）
            └── Combine 流程（收集专家输出）
```
`MoeLayer.forward()` 代码如下:
```python
# megatron/core/transformer/moe/moe_layer.py
# MoE forward: route -> dispatch -> compute -> combine
def forward(self, hidden_states: torch.Tensor):
    def custom_forward(hidden_states):
        shared_expert_output = self.shared_experts_compute(hidden_states)
        hidden_states, probs, residual = self.router_and_preprocess(hidden_states)
        dispatched_input, probs = self.dispatch(hidden_states, probs)
        output, mlp_bias = self.routed_experts_compute(dispatched_input, probs, residual)
        assert mlp_bias is None, f"mlp_bias is not supported for {type(self.token_dispatcher)}"
        output = self.combine(output, shared_expert_output)
```
token_dispatcher会根据config训练配置的`moe_token_dispatcher_type`和`moe_flex_dispatcher_backend`等参数决定具体用哪一个。

## 1. Dispatch
dispatch下面的combine的三步合起来一共6步。在不同的`moe_token_dispatcher_type`对应的MoE(==AllGather,Alltoall,Flex==)TokenDispatcher类内分别实现，对外只提供如下接口：
```python
# 1. dispatch_preprocess: 准备数据，本地计算，无通信
hidden_states, permuted_probs = token_dispatcher.dispatch_preprocess(
    hidden_states, routing_map, permuted_probs
)

# 2. token_dispatch: 执行通信（All-to-All），发送 tokens 到专家设备
dispatched_input, permuted_probs = token_dispatcher.token_dispatch(hidden_states, permuted_probs)

# 3. dispatch_postprocess: 通信后的本地处理，准备给专家计算
dispatched_input, tokens_per_expert, permuted_probs = token_dispatcher.dispatch_postprocess(
    dispatched_input, permuted_probs
)
```
### 1.1 Alltoall
#### 准备permuted_probs
该类的具体 `dispatch_preprocess` 实现方法里面会调用`permute()`函数去分配alltoall的输入`permuted_probs` 和 `permutated_local_input_tokens`。
```python
# megatron/core/transformer/moe/moe_utils.py
def permute(tokens, routing_map, probs, num_out_tokens, fused, drop_and_pad):
    if drop_and_pad:(这个应该是TP大于1的case)
        # ......
    else:
        # mask [num_tokens, num_experts] -> [num_experts, num_tokens]
        1. routing_map = routing_map.bool().T.contiguous()
        num_tokens = tokens.shape
        # Create a dense expert-to-token mapping from the sparse token-to-expert mapping
        2. token_indices = (
            torch.arange(num_tokens, device=routing_map.device).unsqueeze(0).expand(num_experts, -1)
        )
        3. sorted_indices = token_indices.masked_select(routing_map)
    
        if probs is not None:
            4. permuted_probs = probs.T.contiguous().masked_select(routing_map)

    # use the mapping to permute the tokens
    5. permuted_input = tokens.index_select(0, sorted_indices)

    return permuted_input, permuted_probs, sorted_indices
```
1. routing_map是一个bool数组并转置并变为连续内存(contiguous())：
```python
routing_map = [
    [True,  True,  False],  # token 0 选择了 expert 0 和 1
    [False, True,  True ],  # token 1 选择了 expert 1 和 2
    [True,  False, True ],  # token 2 选择了 expert 0 和 2
    [False, True,  False],  # token 3 选择了 expert 1
]
变为
routing_map_T = [
    [True,  False, True,  False],  # expert 0 接收 token 0, 2
    [True,  True,  False, True ],  # expert 1 接收 token 0, 1, 3
    [False, True,  True,  False],  # expert 2 接收 token 1, 2
]
```
2. 创建一个toke索引的矩阵:
```python
# 每行都是 [0, 1, 2, ..., num_tokens-1]
token_indices = [
    [0, 1, 2, 3],  # expert 0 对应的 token 索引
    [0, 1, 2, 3],  # expert 1 对应的 token 索引
    [0, 1, 2, 3],  # expert 2 对应的 token 索引
]
```
3. 接着按照routing_map逐元素去拿到每个专家要的token的连续索引
```python
# masked_select 按行扫描，提取 True 位置的值
sorted_indices = [0, 2,    # expert 0 的 tokens
                  0, 1, 3,  # expert 1 的 tokens
                  1, 2] 
```
4. 相同方式转置probs并变为连续内存并按照routing_map数据mask，==得到输出permuted_probs（用于dispatch第二个alltoall）==
5. 按照step 3专家的tokens索引去取tokens里面真正的token。permuted_input用于dispatch第一个alltoall
```python
permuted_input = [
    tokens[0],  # expert 0 的第 1 个 token
    tokens[2],  # expert 0 的第 2 个 token
    tokens[0],  # expert 1 的第 1 个 token
    tokens[1],  # expert 1 的第 2 个 token
    tokens[3],  # expert 1 的第 3 个 token
    tokens[1],  # expert 2 的第 1 个 token
    tokens[2],  # expert 2 的第 2 个 token
]
```
### 1.2 Flex
核心调用栈如下：
```cpp
token_dispatcher.dispatch() 
  → fused_a2a.fused_dispatch() 
    → FusedDispatch.apply()  // FusedDispatch的类是torch.autograd.Function, 用apply直接自动管理前后向微分
      → FusedDispatch.forward()
        → buffer.get_dispatch_layout()
        → buffer.dispatch() (来自 deep_ep.Buffer)
      → FusedDispatch.backward() 
        → buffer.combine() (来自 deep_ep.Buffer)
```
DeepEP 的 dispatch CUDA 内核在发送阶段就按 per‑expert、per‑rank 的前缀矩阵把数据直接写到目标专家的连续区间，并返回 num_recv_tokens_per_expert_list 告诉每个本地专家的段长。收到的 recv_x/recv_token_indices/recv_token_probs 已经是排好序的视图，不需要 Python 端再做 permuted_probs 或 permuted_local_input_tokens。换言之，传统 alltoall 先通信后本地重排；DeepEP 把重排合并进通信内核完成。下kernel前的最后一次buffer.py内的 `self.runtime.dispatch()` **会调用到deep_ep.cpp.Buffer类内的internode_dispatch函数**， 这个函数内封装了一次 `internode::notify_dispatch` 和 `internode::dispatch` ，如下：
```python
# deep_ep/buffer.py
recv_x, recv_x_scales, recv_topk_idx, recv_topk_weights, num_recv_tokens_per_expert_list, \
                rdma_channel_prefix_matrix, gbl_channel_prefix_matrix, \
                recv_rdma_channel_prefix_matrix, recv_rdma_rank_prefix_sum, \
                recv_gbl_channel_prefix_matrix, recv_gbl_rank_prefix_sum, \
                recv_src_meta, send_rdma_head, send_nvl_head, event = deep_ep_cpp.Buffer.internode_dispatch(
                x, x_scales, topk_idx, topk_weights,
                num_tokens_per_rank, num_tokens_per_rdma_rank, is_token_in_rank, num_tokens_per_expert,
                0, 0, None, None, None, None,
                expert_alignment, config, getattr(previous_event, 'event', None), async_finish, 
                allocate_on_comm_stream)

# csrc/deep_ep.cpp
internode::notify_dispatch(
  num_tokens_per_rank->data_ptr<int>(),      // 每个 rank 需要接收的 token 数
  moe_recv_counter_mapped,                   // CPU 可见的全局 token 接收计数映射，供后续等待/同步
  num_ranks,                                 // EP 组大小
  num_tokens_per_rdma_rank->data_ptr<int>(), // 每个 RDMA 目标 (同 GPU idx) 的 token 数
  moe_recv_rdma_counter_mapped,              // CPU 可见的 RDMA 维度接收计数
  num_tokens_per_expert->data_ptr<int>(),    // 每个专家的 token 数
  moe_recv_expert_counter_mapped,            // CPU 可见的 per-expert 接收计数（对齐后）
  num_experts,                               // 专家总数
  is_token_in_rank.data_ptr<bool>(),         // [num_tokens, num_ranks] 布尔路由矩阵
  num_tokens,                                // 本 rank token 数
  num_channels,                              // 通道数（=SM/2 或 QP 数，用于分块统计）
  hidden_int4,                               // hidden 维除以 4，计算每 token 字节/清理偏移
  num_scales,                                // FP8 scale 组数（同上，决定 per-token 字节数）
  num_topk,                                  // top-k 数（同上）
  expert_alignment,                          // 专家对齐长度，写 moe_recv_expert_counter_mapped 前做对齐
  rdma_channel_prefix_matrix.data_ptr<int>(),// 生成的 RDMA 发送前缀矩阵（按 dst RDMA × channel）
  recv_rdma_rank_prefix_sum.data_ptr<int>(), // 生成的 RDMA 维度累积计数（接收端按 rank 分段）
  gbl_channel_prefix_matrix.data_ptr<int>(), // 生成的 NVL 发送前缀矩阵（dst RDMA × NVL × channel）
  recv_gbl_rank_prefix_sum.data_ptr<int>(),  // 生成的全局 rank 累积计数（接收端按 rank 分段）
  rdma_buffer_ptr,                           // 对称 RDMA 大缓冲基址（放计数交换/后续数据）
  config.num_max_rdma_chunked_recv_tokens,   // RDMA 缓冲预留的最大接收 chunk token 数（算清理区）
  buffer_ptrs_gpu,                           // NVL 对称缓冲数组指针（每 NVL peer 一个）
  config.num_max_nvl_chunked_recv_tokens,    // NVL 缓冲预留的最大接收 chunk token 数（算清理区）
  barrier_signal_ptrs_gpu,                   // NVL 屏障信号指针数组，做节点内 barrier
  rank,                                      // 本 rank
  comm_stream,                               // 通信流
  config.get_rdma_buffer_size_hint(hidden_int4 * sizeof(int4), num_ranks), // RDMA 缓冲大小（用于断言/清理）
  num_nvl_bytes,                             // NVL 缓冲大小（用于断言/清理）
  low_latency_mode);                         // 是否低时延模式（影响 RDMA 目标映射/同步策略）

internode::dispatch(
  recv_x.data_ptr(),              // 接收侧输出数据缓冲 (BF16/FP8 token)
  recv_x_scales_ptr,              // FP8 时的 scale 缓冲；BF16 时为 nullptr
  recv_topk_idx_ptr,              // 接收的 topk 索引缓冲
  recv_topk_weights_ptr,          // 接收的 topk 概率缓冲
  cached_mode ? nullptr : recv_src_meta->data_ptr(), // 源元数据缓冲 (SourceMeta)
  x.data_ptr(),                   // 发送侧输入 token
  x_scales_ptr,                   // 发送侧输入 scale（FP8）
  topk_idx_ptr,                   // 发送侧 topk 索引
  topk_weights_ptr,               // 发送侧 topk 概率
  cached_mode ? nullptr : send_rdma_head->data_ptr<int>(), // RDMA 发送头部指针（每 RDMA rank 写入偏移）
  cached_mode ? nullptr : send_nvl_head->data_ptr<int>(),  // NVL 发送头部指针（本节点内每 NVL rank）
  cached_mode ? nullptr : recv_rdma_channel_prefix_matrix->data_ptr<int>(), // RDMA 接收前缀矩阵（按 channel）
  cached_mode ? nullptr : recv_gbl_channel_prefix_matrix->data_ptr<int>(),  // NVL 接收前缀矩阵（按 channel）
  rdma_channel_prefix_matrix.data_ptr<int>(),      // 通知阶段计算的 RDMA 发送前缀矩阵
  recv_rdma_rank_prefix_sum.data_ptr<int>(),       // 每 RDMA rank 汇总前缀和（token 数）
  gbl_channel_prefix_matrix.data_ptr<int>(),       // 通知阶段计算的 NVL 发送前缀矩阵
  recv_gbl_rank_prefix_sum.data_ptr<int>(),        // 全局 rank 前缀和（token 数）
  is_token_in_rank.data_ptr<bool>(),               // [num_tokens, num_ranks] 路由布尔矩阵
  num_tokens,                                      // 本 rank 参与的 token 数
  hidden_int4,                                     // hidden/4，用于按 int4 访存
  num_scales,                                      // FP8 scale 组数
  num_topk,                                        // top-k 数目
  num_experts,                                     // 总专家数
  scale_token_stride,                              // scale 跨 token 步长
  scale_hidden_stride,                             // scale 跨 hidden 分块步长
  rdma_buffer_ptr,                                 // RDMA 对称大缓冲基指针
  config.num_max_rdma_chunked_send_tokens,         // RDMA 最大发送 chunk token 数
  config.num_max_rdma_chunked_recv_tokens,         // RDMA 最大接收 chunk token 数
  buffer_ptrs_gpu,                                 // NVL 对称缓冲数组指针（每 NVL peer 一个）
  config.num_max_nvl_chunked_send_tokens,          // NVL 最大发送 chunk token 数
  config.num_max_nvl_chunked_recv_tokens,          // NVL 最大接收 chunk token 数
  rank,                                            // 本进程全局 rank
  num_ranks,                                       // EP 组大小
  cached_mode,                                     // 是否复用上次 layout/handle
  comm_stream,                                     // 通信流
  num_channels,                                    // 通道数（通常=SMs/2 或 QP 数）
  low_latency_mode);                               // 是否低时延模式（IBGDA 纯 RDMA）
```

![[token dispatcher + fuse_a2a 2026-01-13 21.20.17.excalidraw]]

## 2. Combine
```python
# 接着上面1的Dispatch
# 4. combine_preprocess: 专家输出后的本地预处理
output = token_dispatcher.combine_preprocess(expert_output)

# 5. token_combine: 执行通信（All-to-All），收集专家输出
output = token_dispatcher.token_combine(output)

# 6. combine_postprocess: 通信后的本地处理，恢复原始形状
output = token_dispatcher.combine_postprocess(output)
```
### Alltoall
### FLex
