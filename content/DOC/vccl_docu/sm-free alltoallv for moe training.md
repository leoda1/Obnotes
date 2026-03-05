## 前言
### 关于TP = 1的bug
 首先在早期我开 TP=1的时候在 moe 的 1F1B ep overlap 的时候，会出现某个 gemm 算子输入为 null 的情况，而 moe training 大部分为 tp1，所以在要想打开 `--overlap-moe-expert-parallel-comm` 则需要设置 `"mlp": False`，如下：
```python
../Megatron-LM/megatron/core/models/gpt/fine_grained_callables.py
@internal_api
def should_free_input(name, is_moe, config):
    // ...
    free_input_nodes = {
        "mlp": False,
        "moe_combine": True,
        "moe_dispatch": not (enable_deepep or enable_hybridep)
            and (CudaGraphScope.moe_preprocess not in config.cuda_graph_scope),
    }
    // ...
```
以上为我在2025.10.14在 Megatron-LM 提的 issue : [https://github.com/issues/created?issue=NVIDIA%7CMegatron-LM%7C1862](https://github.com/issues/created?issue=NVIDIA%7CMegatron-LM%7C1862)
### 


## Vccl a2av moe overlap training
