## 0. 复现

环境：2 台 `8* h200`，镜像  `vllm:v0.13.0`。
问题描述：在使用 `P2pNcclConnector` 时，存在 requset 进来 decode 侧报错，`NixlConnector` 正常。

### 启动 prefill
```shell
export NCCL_SOCKET_IFNAME=bond0
export GLOO_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO
export NCCL_IB_HCA==mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
export NCCL_NVLS_ENABLE=0
export NCCL_IB_GID_INDEX=3
export VLLM_RPC_TIMEOUT=600000
export VLLM_ENGINE_ITERATION_TIMEOUT_S=600
unset FLAGCX_PATH
export USE_FLAGGEMS=0
nohup vllm serve /inspire/hdd/global_public/public_models/deepseek-ai/DeepSeek-V3.2/ \
        --host 0.0.0.0 \
        --port 20001 \
        --tensor-parallel-size 8 \
        --seed 1024 \
        --served-model-name base_model \
        --max-model-len 10000 \
        --max-num-batched-tokens 10000 \
        --max-num-seqs 256 \
        --trust-remote-code \
        --gpu-memory-utilization 0.8 \
        --kv-transfer-config \   '{"kv_connector":"P2pNcclConnector","kv_role":"kv_producer","kv_buffer_size":"1e10","kv_port":"21001","kv_connector_extra_config":{"proxy_ip":"10.252.200.41","proxy_port":"30002","http_port":"20001"}}' > prefill.log &
```

### 启动 decode
```shell
export NCCL_SOCKET_IFNAME=bond0
export GLOO_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO
export NCCL_IB_HCA==mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
export NCCL_NVLS_ENABLE=0
export NCCL_IB_GID_INDEX=3
export VLLM_RPC_TIMEOUT=600000
export VLLM_ENGINE_ITERATION_TIMEOUT_S=600
export USE_FLAGGEMS=0
unset FLAGCX_PATH
nohup vllm serve /inspire/hdd/global_public/public_models/deepseek-ai/DeepSeek-V3.2/  \
        --host 0.0.0.0 \
        --port 20002 \
        --tensor-parallel-size 8 \
        --seed 1024 \
        --served-model-name base_model \
        --max-model-len 10000 \
        --max-num-batched-tokens 10000 \
        --max-num-seqs 256 \
        --trust-remote-code \
        --gpu-memory-utilization 0.8 \
        --kv-transfer-config \
'{"kv_connector":"P2pNcclConnector","kv_role":"kv_consumer","kv_buffer_size":"8e9","kv_port":"22001","kv_connector_extra_config":{"proxy_ip":"10.252.200.41","proxy_port":"30002","http_port":"20002"}}' > decode.log &
```

### log
* 

## 1. profiler

* 在上述启动脚本内增加环境变量后重新启动：

```shell
--profiler-config '{"profiler":"torch","torch_profiler_dir":"/inspire/hdd/global_user/huxiaohe-p-huxiaohe/liuda/vllm/profiler/prefill","ignore_frontend":true,"torch_profiler_with_stack":false,"torch_profiler_with_memory":true,"max_iterations":3}' \
```

* 在 request 前后增加
```shell
curl -X POST http://<prefill-host>:20001/start_profile
curl -X POST http://<decode-host>:20002/start_profile

curl -s http://<proxy-host>:10001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"base_model",
    "messages":[{"role":"user","content":"解释一下 attention"}],
    "max_tokens":8,
    "stream":false
  }'

curl -X POST http://<prefill-host>:20001/stop_profile
curl -X POST http://<decode-host>:20002/stop_profile
```