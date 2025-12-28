## 1. 概述
使用单边（one-sided）无核（sm-free）对称内存（symmetric memory）点对点通信接口实现MoE中的dispatch & combine过程的AlltoAll集合通信操作。换言之，实现一个无核的DeepEP。
在megatron的框架下，使能MoE 1F1B overlap（overlap-moe-expert-parallel-comm）时，MoE在一个PP stage的model trunk的不同layer的前向过程和后向过程实现了计算和通信的Overlap，即前向的计算和后向的通信，或前向的通信和后向的计算相互Overlap，隐藏通信的时间。因此，使用sm-free的通信可减少通信对SM资源的竞争，加速计算。事先分配和RDMA注册对称内存实现zero-copy点对点通信，减少中等数据大小通信的延迟。单边通信方式更易于AlltoAll编程的实现。
具体地讲在megatron侧，实现通信使用buffer的对称内存的分配和RDMA注册。在VCCL侧，参考DeepEP的dispatch&combine的实现和NCCL 2.28代码中机内无核AlltoAll的实现，假设在一个EP中包括了8个rank，分布在两个node上，每个rank要发送token本地node的其他3个rank，以及发送token给另一个node上的4个rank，于此通信，接收所有其他rank的token。跨机传输token的时候，这个rank把数据先发送给对端node的同号GPU，然后，由这个rank再把token分发到其他该node的其他GPU。其余每个rank都进行同样的流程。如下图所示。
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20251228120151206.png)
问题：是否可以通过multimem机制加速接收侧PXN数据交换的过程？原则上，需要确认除了PTX之外，是否有CUDA接口可以访问multimem？

## 2. Megatron
### 2.1 计算和通信的Overlap
主要实现代码：
megatron/core/pipeline_parallel/combined_1f1b.py
megatron/core/models/gpt/fine_grained_callables.py
megatron/core/pipeline_parallel/utils.py
megatron/core/models/common/model_chunk_schedule_plan.py
从nsight产生的trace看，MoE计算和通信不能完全overlap，我们分析其中的原因在于类似combine的scatter_add操作启动了大量（16384 * 128）的kernel threads，其他的计算算子的block没有机会调度到SM上面去。实现不同任务的并行Overlap，除了任务之间没有依赖，被提交到不同的CUDA stream上之外，还受限于严格的计算资源的限制条件（参考：[https://arxiv.org/html/2501.16909v1](https://arxiv.org/html/2501.16909v1)）
### 2.2 对称内存的分配和注册
#### 2.2.1 Input Buffer to be Dispatched
![](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20251228120739493.png)
$$size\_of\_tokens\_per\_rank=num\_tokens \times num\_local\_experts \times top\_k \times hidden\_size \times size\_of\_elemment$$
$$size\_of\_meta\_per\_rank = 4+4+4+4+num\_local\_experts\times 4 + num\_tokens \times 4$$
$$size\_of\_data\_per\_rank=size\_of\_meta\_per\_rank  +size\_of\_tokens\_per\_rank$$
$$size\_of\_rdma\_rank = 4+4+num\_local\_ranks \times size\_of\_data\_per\_rank$$
$$ input\_dispatch\_buffer\_size = size\_of\_rdma\_rank \times num\_rdma\_ranks$$
#### 2.2.2 RDMA Buffer being Dispached
$$rdma\_buffer\_size = size\_of\_data\_per\_rank \times num\_local\_ranks$$
#### 2.2.3 Output Buffer Dispatched
$$out\_buffer\_size = size\_of\_data\_per\_rank \times num\_ranks$$
### 2.3 其他
需要事先分配和注册的buffer和AlltoAll的操作有关。
dispatch包括两个AlltoAll（tokens和对应的probs）过程：
- 按照发送目的rank重排后的输入token tensor（permutated local input tokens）；
- 对应的按照发送目的rank重排后的token prob tensor（permutated probalilities）；
- 输出的token tensor，即接收其他rank发送到本地专家的token数据；
- AlltoAll的输出token prob，即接收其他rank发送到本地专家的token prob数据。
如下代码所示。
```python
# megatron/core/transformer/moe/token_dispatcher.py
def token_dispatch(self, permutated_local_input_tokens, permuted_probs):
    # Perform expert parallel AlltoAll communication
    self.tokens_per_expert = self._maybe_dtoh_and_synchronize(
        "before_ep_alltoall", self.tokens_per_expert
    )
    global_input_tokens = all_to_all(
        self.ep_group, permutated_local_input_tokens, self.output_splits, self.input_splits
    )
    global_probs = all_to_all(
        self.ep_group, permuted_probs, self.output_splits, self.input_splits
    )
    return global_input_tokens, global_probs
```
输入的tensor在megatron/core/transformer/moe/moe_utils.py:def permute(...)中分配产生，如下面的代码所示。
```python
# megatron/core/transformer/moe/moe_utils.py
def permute(
    tokens,
    routing_map,
    probs: Optional[torch.Tensor] = None,
    num_out_tokens: Optional[int] = None,
    fused: bool = False,
    drop_and_pad: bool = False,
):
    # ... ... ... ...
        # mask [num_tokens, num_experts] -> [num_experts, num_tokens]
    routing_map = routing_map.bool().T.contiguous()

    # Create a dense expert-to-token mapping from the sparse token-to-expert mapping
    token_indices = (
         torch.arange(num_tokens, device=routing_map.device).unsqueeze(0).expand(num_experts, -1)
    )
    # token indices per each expert
    sorted_indices = token_indices.masked_select(routing_map)

    if probs is not None:
        # token probabilities per each expert
        permuted_probs = probs.T.contiguous().masked_select(routing_map)

    # use the mapping to permute the tokens
    #tokens per each expert
    permuted_input = tokens.index_select(0, sorted_indices)

    return permuted_input, permuted_probs, sorted_indices
```
输出的tensor在megatron/core/tensor_parallel/mappings.py:\_AllToAll:forward(...)中分配。
```python
def forward(ctx, group, input, output_split_sizes, input_split_sizes):
        """Forward function."""
        ctx.group = group
        ctx.output_split_sizes = output_split_sizes
        ctx.input_split_sizes = input_split_sizes

        world_size = group.size()
        # Bypass the function if we are using only 1 GPU.
        if world_size == 1:
            return input

        input = input.contiguous()
        if output_split_sizes is None:
            # Equal split (all2all)
            output = torch.empty_like(input)
        else:
            # Unequal split (all2all-v)
            output = input.new_empty(
                size=[sum(output_split_sizes)] + list(input.size()[1:]),
                dtype=input.dtype,
                device=torch.cuda.current_device(),
            )
        torch.distributed.all_to_all_single(
            output,
            input,
            output_split_sizes=output_split_sizes,
            input_split_sizes=input_split_sizes,
            group=group,
        )
        return output
```
combine的过程与之相反。
