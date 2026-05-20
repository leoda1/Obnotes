# v3.1
官方配置说明： https://huggingface.co/deepseek-ai/DeepSeek-V3.1?utm_source=chatgpt.com
里面
## using DeepEP

```shell title=""
# 1. 安装 nccl 的 so
pip install "nvidia-nccl-cu13>=2.30.4" --no-deps
# 2. 安装nvshmem
pip install --extra-index-url https://pypi.nvidia.com \  
"nvidia-nvshmem-cu13>=3.6.5"
# 3. git clone deepep
# 4. deepep代码内
export TORCH_CUDA_ARCH_LIST="10.3"
python setup.py install
# 5. 使用前指定 deepep 用的 nccl 的 so
export NCCL_HOME=/usr/local/lib/python3.12/dist-packages/nvidia/nccl
export LD_LIBRARY_PATH=$NCCL_HOME/lib:$LD_LIBRARY_PATH
```
目前一直报错deepepManager 找不到 但是 deepep 已经 install 成功可以单测deepep 的 test 程序。。。。

## using nccl alltoall
只需将 vccl alltoallv 的config.sh模型配置改成 alltoall 就行

## using vccl alltoallv
### 启动脚本和参数
```shell title='mpi_vccl.sh'
#! /bin/bash

TIMESTAMP=$(date +'%Y.%m.%d-%H:%M:%S')

NET_DEVICE="bond0"
MLP_GPU=8
MLP_MPI_HOSTFILE=$2
MLP_WORKER_0_PORT=29500
MLP_WORKER_NUM=$3
source $1

mkdir -p logs/${EXP_NAME}
mpirun -np $((MLP_WORKER_NUM * MLP_GPU)) \
        --hostfile ${MLP_MPI_HOSTFILE} \
        --allow-run-as-root   \
        --output-filename logs/${TIMESTAMP} \
        --mca oob_tcp_if_include ${NET_DEVICE} \
        -x NCCL_IB_TC=106 \
        -x NCCL_IB_GID_INDEX=3 \
        -x NCCL_DEBUG=WARN \
        -x NCCL_IB_HCA==roce_vf_rail0:1,roce_vf_rail1:1,roce_vf_rail2:1,roce_vf_rail3:1,roce_vf_rail4:1,roce_vf_rail5:1,roce_vf_rail6:1,roce_vf_rail7:1 \
	-x PATH \
	-x NCCL_NET_PLUGIN=None \
        -x PYTHONPATH="${PYTHONPATH}:/workspace/daliu/VCCL/nccl4py" \
        -x LD_LIBRARY_PATH=/workspace/daliu/VCCL/build/lib:$LD_LIBRARY_PATH \
	-x MASTER_ADDR=$(cat $MLP_MPI_HOSTFILE | head -n 1 | sed -s 's/slots=8//g') \
        -x MASTER_PORT=${MLP_WORKER_0_PORT} \
        -x GLOO_SOCKET_IFNAME=${NET_DEVICE} \
        -x NCCL_SOCKET_IFNAME=${NET_DEVICE} \
        -x UCX_NET_DEVICES=${NET_DEVICE} \
        -x CUDA_DEVICE_MAX_CONNECTIONS=32 \
        -x NCCL_PXN_DISABLE=1 \
        -x NCCL_PASS_SM=0 \
        -x NCCL_CUMEM_ENABLE=1 \
        python ${script_path} ${gpt_options} 2>&1 | tee logs/${EXP_NAME}/output_${TIMESTAMP}.log
```

```shell title="config.sh  -- 1node"
#!/bin/bash
EXP_NAME="deepseek-v31-bench"
script_path="pretrain_gpt.py"

MODEL_ARGS="
    --use-mcore-models
    --disable-bias-linear
    --seq-length 2048
    --max-position-embeddings 163840
    --num-layers 61
    --hidden-size 7168
    --ffn-hidden-size 18432
    --num-attention-heads 128
    --kv-channels 128
    --init-method-std 0.02
    --attention-dropout 0.0
    --hidden-dropout 0.0
    --normalization RMSNorm
    --norm-epsilon 1e-6
    --position-embedding-type rope
    --rope-type yarn
    --rotary-base 10000
    --rotary-scaling-factor 40
    --swiglu
    --untie-embeddings-and-output-weights
    --multi-latent-attention
    --qk-layernorm
    --q-lora-rank 1536
    --kv-lora-rank 512
    --qk-head-dim 128
    --qk-pos-emb-head-dim 64
    --v-head-dim 128
    --mscale 1.0
    --mscale-all-dim 1.0
    --no-masked-softmax-fusion
"
#--seq-length is 4096

MOE_ARGS="
    --num-experts 8
    --moe-layer-freq [0]*3+[1]*58
    --moe-ffn-hidden-size 2048
    --moe-shared-expert-intermediate-size 2048
    --moe-router-topk 2
    --moe-router-load-balancing-type none
    --moe-router-num-groups 2
    --moe-router-group-topk 1
    --moe-router-score-function sigmoid
    --moe-router-pre-softmax
    --moe-router-topk-scaling-factor 2.5
    --moe-router-enable-expert-bias
    --moe-router-bias-update-rate 1e-3
    --moe-token-dispatcher-type alltoallv
    --moe-grouped-gemm
    --moe-router-force-load-balancing
"
    # --overlap-moe-expert-parallel-comm
    # --num-experts 256
    # --moe-router-topk 8
    # --moe-router-num-groups 8
    # --moe-router-group-topk 4

MTP_ARGS="
    --mtp-num-layers 1
"

#    --delay-wgrad-compute
DATA_ARGS="
    --vocab-size 129280 \
    --tokenizer-type Llama2Tokenizer \
    --tokenizer-model ./moe/tokenizer.model \
    --data-path ./moe/wudao_mistralbpe_content_document \
    --split 949,50,1
"

TRAINING_ARGS="
    --micro-batch-size 1 \
    --global-batch-size 512 \
    --lr 1e-4 \
    --train-iters 20000 \
    --lr-decay-iters 320000 \
    --lr-decay-style cosine \
    --min-lr 1.0e-5 \
    --weight-decay 0.1 \
    --lr-warmup-iters 0 \
    --clip-grad 1.0 \
    --bf16 \
"
#--micro-batch-size 2
#--recompute-granularity selective \
MODEL_PARALLEL_ARGS="
    --tensor-model-parallel-size 1 \
    --pipeline-model-parallel-size 4 \
    --expert-model-parallel-size 2 \
    --expert-tensor-parallel-size 1 \
    --pipeline-model-parallel-layout Et*16|t*15|t*15|t*15,mL \
    --context-parallel-size 1 \
    --use-distributed-optimizer \
    --sequence-parallel \
    --use-flash-attn \
"

LOGGING_ARGS="
    --log-interval 1 \
    --eval-iters 0 \
    --eval-interval 10000 \
    --save-interval 10000 \
    --no-load-optim \
    --no-load-rng \
    --log-throughput \
    --timing-log-level 0 \
"
    # --distributed-timeout-minutes 60 \
gpt_options="
    ${MODEL_ARGS} \
    ${MODEL_PARALLEL_ARGS} \
    ${MOE_ARGS} \
    ${MTP_ARGS} \
    ${DATA_ARGS} \
    ${TRAINING_ARGS} \
    ${LOGGING_ARGS} \
"
```
### 问题

a. v3.1 的模型配置跑的时候会直接报错 recvbuff 是 null， 

```py
[2026-05-19 14:56:00] gpu001:57450:57450 [1] enqueue.cc:3001 VCCL WARN RMA coll: recvbuff is NULL
gpu001:57450:57450 [1] VCCL INFO enqueue.cc:3071 -> 4
gpu001:57450:57450 [1] VCCL INFO enqueue.cc:3189 -> 4
gpu001:57450:57450 [1] VCCL INFO enqueue.cc:3194 -> 4
WARNING:megatron.core.utils:InvalidArgument (4): invalid argument (run with NCCL_DEBUG=WARN for details)
```

分析原因及解决办法如下：

原因：从模型配置和 moe 代码层面看，v3.1需要开 `--moe-router-num-groups 8`和 `--moe-router-group-topk 4`这两个环境变量。例如 v3.1的配置下就是 256 个专家，8 个专家组，每个 token 需要发给  group_topk 个组和组内的topk 个专家，故需要==严格保证组内专家数大于 topk，否则会出现一个 recv token 是 0 的 alltoallv，这里 nccl 是支持空的 alltoall 不会报错，我们是直接报错退出。==
解决办法：单机情况下，8 个专家，2 个组，每次选1个组，一个组内发给 2 个专家，2>1就可以跑了。

b. ==加了下面代码后可以跑v3.1或者 mixtral==，不然会报错：
```python
def combine_preprocess(self, hidden_states: torch.Tensor) -> torch.Tensor:
        hidden_states = super().combine_preprocess(hidden_states)
        if (
            hidden_states.untyped_storage().data_ptr()
            != self._manager._input_token_fwd_storage_ptr
        ):
            N, H = hidden_states.shape
            buf = (
                self._manager.input_token_fwd_tensor
                .view(hidden_states.dtype)[: N * H]
                .view(N, H)
            )
            buf.copy_(hidden_states)####111
            hidden_states = buf
        return hidden_states

[rank1]:   File "/workspace/daliu/vccl-megatron/megatron/core/transformer/transformer_layer.py", line 491, in forward
[rank1]:     output = self._forward_mlp(hidden_states, kwargs.get("inference_context", None))
[rank1]:              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank1]:   File "/workspace/daliu/vccl-megatron/megatron/core/transformer/transformer_layer.py", line 715, in _forward_mlp
[rank1]:     mlp_output_with_bias = self.mlp(pre_mlp_layernorm_output)
[rank1]:                            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank1]:   File "/usr/local/lib/python3.12/dist-packages/torch/nn/modules/module.py", line 1778, in _wrapped_call_impl
[rank1]:     return self._call_impl(*args, **kwargs)
[rank1]:            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank1]:   File "/usr/local/lib/python3.12/dist-packages/torch/nn/modules/module.py", line 1789, in _call_impl
[rank1]:     return forward_call(*args, **kwargs)
[rank1]:            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank1]:   File "/workspace/daliu/vccl-megatron/megatron/core/transformer/moe/moe_layer.py", line 391, in forward
[rank1]:     outputs = custom_forward(hidden_states)
[rank1]:               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank1]:   File "/workspace/daliu/vccl-megatron/megatron/core/transformer/moe/moe_layer.py", line 375, in custom_forward
[rank1]:     output = self.combine(output, shared_expert_output)
[rank1]:              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank1]:   File "/workspace/daliu/vccl-megatron/megatron/core/transformer/moe/moe_layer.py", line 320, in combine
[rank1]:     output = self.token_dispatcher.token_combine(output)
[rank1]:              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank1]:   File "/workspace/daliu/vccl-megatron/tests/vccl/vccl_utils.py", line 1413, in token_combine
[rank1]:     permutated_local_input_tokens = self._manager.combine(hidden_states)
[rank1]:                                     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank1]:   File "/workspace/daliu/vccl-megatron/tests/vccl/vccl_utils.py", line 978, in combine
[rank1]:     tokens.untyped_storage().data_ptr() == self._input_token_fwd_storage_ptr
[rank1]: AssertionError: VCCLManager: tokens must share storage with input_token_fwd_tensor
```

## 结论

|                   | deepep | nccl a2a | vccl a2av |
| ----------------- | ------ | -------- | --------- |
| v3.1(with 1 node) |        | ✅        | ✅         |

# QWEN
## using vccl a2av
### 启动脚本和参数
```py title=""

```


```sh title="mpi_vccl.sh"
同上面
```


```shell title='config.sh'
#!/bin/bash
EXP_NAME="qwen-235b"
script_path="pretrain_gpt.py"

MODEL_ARGS="
    --save-interval 100000 \
    --no-masked-softmax-fusion \
    --disable-bias-linear \
    --untie-embeddings-and-output-weights \
    --position-embedding-type rope \
    --no-rope-fusion \
    --normalization RMSNorm \
    --swiglu \
    --num-layers 94 \
    --hidden-size 4096 \
    --ffn-hidden-size 12288 \
    --num-attention-heads 64 \
    --group-query-attention \
    --num-query-groups 4 \
    --kv-channels 128 \
    --qk-layernorm \
    --num-experts 8 \
    --seq-length 4096 \
    --max-position-embeddings 40960 \
    --make-vocab-size-divisible-by 1187 \
    --use-mcore-models \
    --rotary-percent 1.0 \
    --rotary-base 1000000 \
    --rotary-seq-len-interpolation-factor 1 \
    --no-bias-swiglu-fusion \
    --attention-dropout 0.0 \
    --hidden-dropout 0.0 \
    --account-for-loss-in-pipeline-split \
    --account-for-embedding-in-pipeline-split \
"
# --num-experts 128 \
MOE_ARGS="
    --moe-ffn-hidden-size 1536
    --moe-router-topk 8
    --moe-router-dtype fp32
    --moe-aux-loss-coeff 1e-3
    --moe-router-load-balancing-type aux_loss
    --moe-layer-recompute
    --moe-grouped-gemm
    --overlap-moe-expert-parallel-comm
    --moe-token-dispatcher-type alltoallv
    --moe-router-force-load-balancing
"

#    --delay-wgrad-compute
DATA_ARGS="
    --vocab-size 129280 \
    --tokenizer-type Llama2Tokenizer \
    --tokenizer-model ./moe/tokenizer.model \
    --data-path ./moe/wudao_mistralbpe_content_document \
    --split 949,50,1
"

TRAINING_ARGS="
    --micro-batch-size 1 \
    --global-batch-size 512 \
    --lr 1e-4 \
    --train-iters 20000 \
    --lr-decay-iters 320000 \
    --lr-decay-style cosine \
    --min-lr 1.0e-5 \
    --weight-decay 0.1 \
    --lr-warmup-iters 0 \
    --clip-grad 1.0 \
    --bf16 \
"

MODEL_PARALLEL_ARGS="
    --tensor-model-parallel-size 1 \
    --pipeline-model-parallel-size 4 \
    --expert-model-parallel-size 2 \
    --expert-tensor-parallel-size 1 \
    --num-layers-per-virtual-pipeline-stage 4 \
    --context-parallel-size 1 \
    --use-distributed-optimizer \
    --sequence-parallel \
    --use-flash-attn \
"

LOGGING_ARGS="
    --log-interval 1 \
    --eval-iters 0 \
    --eval-interval 10000 \
    --save-interval 10000 \
    --no-load-optim \
    --no-load-rng \
    --log-throughput \
    --timing-log-level 0 \
"
    # --distributed-timeout-minutes 60 \
gpt_options="
    ${MODEL_ARGS} \
    ${MODEL_PARALLEL_ARGS} \
    ${MOE_ARGS} \
    ${DATA_ARGS} \
    ${TRAINING_ARGS} \
    ${LOGGING_ARGS} \
"
```



### 问题
1. qwen 会用 `--moe-router-dtype fp32`， 而权重是 `--bf16`，在 vccl_utills 内 hardcode 成一模一样，然后导致用权重的精度去存 probs ，报错是：
```py
[rank0]:   File "/workspace/daliu/vccl-megatron/tests/vccl/vccl_utils.py", line 1302, in token_dispatch
[rank0]:     global_input_tokens, global_probs = self._manager.dispatch(
[rank0]:                                         ^^^^^^^^^^^^^^^^^^^^^^^
[rank0]:   File "/workspace/daliu/vccl-megatron/tests/vccl/vccl_utils.py", line 867, in dispatch
[rank0]:     assert probs.dtype == self._params_dtype, (
[rank0]:            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[rank0]: AssertionError: VCCLManager: probs dtype torch.float32 does not match params_dtype torch.bfloat16
```
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20260520154139135.png)

```sh title="需要修改的 diff"
diff --cc tests/vccl/vccl_utils.py
index ff1ecc6c3,fe09bed44..000000000
--- a/tests/vccl/vccl_utils.py
+++ b/tests/vccl/vccl_utils.py
@@@ -547,9 -548,9 +547,10 @@@ class VCCLManager
          # TODO: buffer size may need to be aligned to 128B ?
          element_size = get_sizeof(params_dtype)
          self._element_size = element_size
--        unit = bs * seq_len * topk * element_size
--        token_unit = unit * hidden_size
--        prob_unit = unit  # "1" in (hidden_size + 1) corresponds to probs
++        token_count = bs * seq_len * topk
++        token_unit = token_count * hidden_size * element_size
++        # Prob buffers are sized for fp32 (4 bytes) so any router dtype fits without overflow.
++        prob_unit = token_count * 4
          # To prevent overflow, actual buffer sizes are reserved at 2x the minimum unit
          token_buf_size = token_unit * 2
          prob_buf_size = prob_unit * 2
@@@ -786,20 -798,24 +787,24 @@@
          ``_base_buf_size = token_unit + prob_unit``. Total is
          ``_buf_size == 10 * _base_buf_size``.
          """
 -        # Each sub-buffer has its own independent allocation at offset=0,
 -        # so no offset arithmetic can produce a NULL address.
 -        for (buf_attr, size_attr), raw_buf in zip(self._VCCL_BUFFER_SPECS, self._sub_buffers):
 +        #self.input_buffer = VcclBuffer(self._buffer, size=self._base_buf_size, offset=0)
 +        offset = 0
 +        for buf_attr, size_attr in self._VCCL_BUFFER_SPECS:
              size = getattr(self, size_attr)
 -            buffer = VcclBuffer(raw_buf, size=size, offset=0)
 +            buffer = VcclBuffer(self._buffer, size=size, offset=offset)
              setattr(self, buf_attr, buffer)
--            # Pre-cache a 1D typed tensor at params_dtype so dispatch/combine
--            # can skip the per-call to_tensor() path and just slice+reshape.
 -            tensor = buffer.to_tensor(
 -                shape=(size // self._element_size,), dtype=self._params_dtype
 -            )
 -            # Guard against VA wrap-around producing a NULL tensor.
 -            assert tensor.data_ptr() != 0, (
 -                f"{self.__class__.__name__}: {buf_attr} tensor has NULL data_ptr! "
 -                f"raw_ptr={buffer._raw_ptr:#x}, size={size}. "
 -                "ncclMemAlloc returned an address that maps to NULL."
++            # Pre-cache a 1D typed tensor so dispatch/combine can skip the
++            # per-call to_tensor() path. Prob buffers use fp32 (sized for worst-case
++            # dtype); token buffers use params_dtype.
++            is_prob = "prob" in buf_attr
++            buf_dtype = torch.float32 if is_prob else self._params_dtype
++            buf_el_size = 4 if is_prob else self._element_size
 +            setattr(
 +                self,
 +                buf_attr.replace("_buffer", "_tensor"),
-                 buffer.to_tensor(shape=(size // self._element_size,), dtype=self._params_dtype),
++                buffer.to_tensor(shape=(size // buf_el_size,), dtype=buf_dtype),
              )
 -            setattr(self, buf_attr.replace("_buffer", "_tensor"), tensor)
 +            offset += size
  
      def __del__(self):
          # self._free_memory()
@@@ -847,10 -864,10 +852,6 @@@
              f"{self.__class__.__name__}: tokens must share storage with input_token_fwd_tensor"
          )
          if probs is not None:
--            assert probs.dtype == self._params_dtype, (
--                f"{self.__class__.__name__}: probs dtype {probs.dtype} "
--                f"does not match params_dtype {self._params_dtype}"
--            )
              assert (
                  probs.untyped_storage().data_ptr() == self._input_prob_fwd_storage_ptr
              ), (
@@@ -876,7 -893,7 +877,7 @@@
              :output_token_tensor_len
          ].view(expected_num_recv_tokens, H)
          output_prob_tensor = (
--            self.output_prob_fwd_tensor[:output_prob_tensor_len].view(
++            self.output_prob_fwd_tensor.view(probs.dtype)[:output_prob_tensor_len].view(
                  expected_num_recv_tokens
              )
              if probs is not None
@@@ -890,14 -907,14 +891,14 @@@
              :input_token_tensor_len
          ].view(expected_num_send_tokens, H)
          input_prob_bwd_tensor = (
--            self.input_prob_bwd_tensor[:output_prob_tensor_len].view(
++            self.input_prob_bwd_tensor.view(probs.dtype)[:output_prob_tensor_len].view(
                  expected_num_recv_tokens
              )
              if probs is not None
              else None
          )
          output_prob_bwd_tensor = (
--            self.output_prob_bwd_tensor[:input_prob_tensor_len].view(
++            self.output_prob_bwd_tensor.view(probs.dtype)[:input_prob_tensor_len].view(
                  expected_num_send_tokens
              )
              if probs is not None
@@@ -916,7 -933,7 +917,7 @@@
                  self.dispatch_prob_sdispls,
                  self.dispatch_prob_recvcounts,
                  self.dispatch_prob_rdispls,
--                self._nccl_dtype,
++                _to_nccl_dtype(probs.dtype),
                  self.relay_tensor,
                  stream_ptr,
              )
```