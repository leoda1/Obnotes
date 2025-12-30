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
### MoEAlltoallTokenDispatcher
#### 准备permuted_probs
该类的具体 `dispatch_preprocess` 实现方法里面会调用`permute()`函数去分配alltoall的输入`permuted_probs`。
```python
# megatron/core/transformer/moe/moe_utils.py
def permute():
    if drop_and_pad:
        # ......
    else:
        # mask [num_tokens, num_experts] -> [num_experts, num_tokens]
        1. routing_map = routing_map.bool().T.contiguous()
    
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
### FLex


## Combine
```python
# 4. combine_preprocess: 专家输出后的本地预处理
output = token_dispatcher.combine_preprocess(expert_output)

# 5. token_combine: 执行通信（All-to-All），收集专家输出
output = token_dispatcher.token_combine(output)

# 6. combine_postprocess: 通信后的本地处理，恢复原始形状
output = token_dispatcher.combine_postprocess(output)
```
### Alltoall
### FLex