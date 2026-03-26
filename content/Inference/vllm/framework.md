## 0. 环境变量/启动参数相关

 例如docs/design/p2p_nccl_connector.md 内 pd 分离的启动脚本，这里主要体现了 VLLM 的环境变量（`VLLM_*`）和启动参数（`--*****`）
```py title="decode.sh"
export VLLM_RPC_TIMEOUT=600000
export VLLM_ENGINE_ITERATION_TIMEOUT_S=600
export USE_FLAGGEMS=0
unset PYTHONPATH
export PYTHONPATH=1
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
        --gpu-memory-utilization 0.9 \
        --kv-transfer-config \
        '{"kv_connector":"P2pNcclConnector","kv_role":"kv_consumer","kv_buffer_size":"8e9","kv_port":"22001","kv_connector_extra_config":{"proxy_ip":"10.254.11.128","proxy_port":"30002","http_port":"20002"}}' > decode-ori.log &
```

### a. 定义位置

| 文件                         | 内容                                                                                                                                                                                                                                                                                                                                                |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| vllm/envs.py               | vLLM 所有**环境变量**的唯一集中定义处（[TYPE_CHECKING](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 块做类型声明，下方 dict 做运行时解析）                                                                                                                                     |
| vllm/config/scheduler.py   | 调度器参数：[max_num_seqs](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html)、[max_num_batched_tokens](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 等     |
| vllm/config/cache.py       | KV cache 参数：[gpu_memory_utilization](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html)、[block_size](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 等 |
| vllm/config/kv_transfer.py | PD 分离 KV 传输参数：[kv_connector](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html)、[kv_role](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 等            |
| vllm/engine/arg_utils.py   | 把上面所有参数 config 字段注册为 [vllm serve](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 的 CLI 参数                                                                                                                                                         |
### b. kv_transfer_config

vllm serve的 cli 参数在我们启动时候假设指定为下面的：
```py title=""
--kv-transfer-config \

'{"kv_connector":"P2pNcclConnector","kv_role":"kv_consumer","kv_buffer_size":"8e9","kv_port":"22001","kv_connector_extra_config":{"proxy_ip":"10.254.11.128","proxy_port":"30002","http_port":"20002"}}' > decode-ori.log &
```

vllm 会分为三个阶段去处理：

**阶段一：cli 字符串 ---> `KVTransferConfig` 对象**
在 arg_utils.py内的函数 `_compute_kwargs` 会遍历到 `KVTransferConfig` ， 发现是用了@config修饰为（dataclass）的类，然后会给外面的库函数TypeAdapter去解析这个 `KVTransferConfig`，去实现命令行的字符串变为 python 对象，钩子名就叫[type=parse_dataclass](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 。

**阶段二：把`KVTransferConfig` 对象实例化为 `P2pNcclConnector`**
用户传入后，argparse 解析完把结果塞进命名空间，然后 [EngineArgs](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 拿到的就是已经实例化好的 [KVTransferConfig](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 对象。接着 vllm 的 scheduler/Worker/KV connectorFactor 就会自己去按照这里的参数初始化。

Scheduler 侧初始化 — [scheduler.py:127]
```py title=""
if self.vllm_config.kv_transfer_config is not None:
    self.connector = KVConnectorFactory.create_connector(
        config=self.vllm_config,
        role=KVConnectorRole.SCHEDULER,
        ...
    )
```

Worker 侧初始化 — [kv_transfer_state.py:67]
```py title=""
_KV_CONNECTOR_AGENT = KVConnectorFactory.create_connector(
    config=vllm_config,
    role=KVConnectorRole.WORKER,
    ...
)
```

[KVConnectorFactory] 按名字查注册表 — [factory.py:159]
```py title=""
# 文件末尾的静态注册：
KVConnectorFactory.register_connector(
    "P2pNcclConnector",                                    # ← 与 kv_connector 字段匹配
    "vllm.distributed.kv_transfer.kv_connector.v1.p2p.p2p_nccl_connector",
    "P2pNcclConnector",
)
```
注册时只记录 **模块路径 + 类名**（懒加载），[create_connector](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 调用时才 [importlib.import_module()](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) 真正加载。

**阶段三：实例化真正的 NCCL connector**
```py title=""
class P2pNcclConnector(KVConnectorBase_V1):
    def __init__(self, vllm_config, role, kv_cache_config=None):
        ...
        # role==WORKER 时才创建真正的 NCCL 通信引擎
        self.p2p_nccl_engine = (
            P2pNcclEngine(local_rank=..., config=self._kv_transfer_config, ...)
            if role == KVConnectorRole.WORKER else None
        )
```

整个  kv_transfer_config 初始化的流程就是：
```txt title=" kv_transfer_config 初始化的流程"
 --kv-transfer-config '{"kv_connector":"P2pNcclConnector",...}'
        │
        │ argparse + TypeAdapter.validate_json()
        ▼
KVTransferConfig(kv_connector="P2pNcclConnector", kv_role="kv_consumer", ...)
        │
        │ EngineArgs.create_engine_config()
        ▼
VllmConfig.kv_transfer_config = <KVTransferConfig>
        │
        ├─── Scheduler.__init__() ──► KVConnectorFactory.create_connector(role=SCHEDULER)
        │                                      │
        └─── Worker 初始化           ──► KVConnectorFactory.create_connector(role=WORKER)
                                              │
                              查 _registry["P2pNcclConnector"]
                              importlib.import_module("...p2p_nccl_connector")
                                              │
                                              ▼
                                   P2pNcclConnector.__init__()
                                              │ role==WORKER
                                              ▼
                                     P2pNcclEngine(...)  ← 真正建立 ZMQ + NCCL 通信
```

### c. 

## 1. serving benchmark result 怎么分析

**当拿到一份 vllm 输出的 serving 后，评价指标怎么看？**
### 第一步：先看 12 和 15
这两个是**最核心的两个指标**，因为它们直接对应 1P1D 的两个节点，一般 TPOT 在 50ms 内就可以通过验收

| 指标               | 对应节点           | 物理含义                                |
| ---------------- | -------------- | ----------------------------------- |
| **12 Mean TTFT** | **Prefill 节点** | 从发请求 → 收到第1个token，主要耗在把 prompt 全部算完 |
| **15 Mean TPOT** | **Decode 节点**  | 每生成1个后续token的平均耗时（第1个不算）            |
```py title="1P1P nccl connector for Deepseek V3.2"
============ Serving Benchmark Result ============
Successful requests:                     417       
Failed requests:                         1193      
Request rate configured (RPS):           0.60      
Benchmark duration (s):                  2811.39   
Total input tokens:                      1702144   
Total generated tokens:                  407575    
Request throughput (req/s):              0.15      
Output token throughput (tok/s):         144.97    
Peak output token throughput (tok/s):    840.00    
Peak concurrent requests:                27.00     
Total token throughput (tok/s):          750.42    
---------------Time to First Token----------------
Mean TTFT (ms):                          788.59    
Median TTFT (ms):                        500.98    
P99 TTFT (ms):                           11254.71  
-----Time per Output Token (excl. 1st token)------
Mean TPOT (ms):                          27.55     
Median TPOT (ms):                        26.85     
P99 TPOT (ms):                           33.03     
---------------Inter-token Latency----------------
Mean ITL (ms):                           27.39     
Median ITL (ms):                         26.53     
P99 ITL (ms):                            32.01     
==================================================
```
- 单请求 decode 速度看 TPOT/ITL。你这次 Mean TPOT = 27.55 ms，所以一个“已经进入稳定 decode 的请求”平均大约是 1 / 0.02755 ≈ 36 tok/s。P99 TPOT = 33.03 ms 对应尾部大约 30 tok/s。你用 1/0.033 这个算法本身没问题，但它只表示“单个活跃请求”的尾部 token 速度。
- 整体 decode goodput 看 Output token throughput = 144.97 tok/s。这是全局平均，不是单请求速度。它和上面的 36 tok/s/request 不矛盾，表示整段运行里平均只有大约 145 / 36 ≈ 4 个请求等效地处在活跃 decode 状态。Peak output token throughput = 840 tok/s 则对应峰值大约 840 / 36 ≈ 23 个活跃 decode 流，和你 Peak concurrent requests = 27 是对得上的。
- Request throughput = 0.15 req/s 是端到端成功完成率，等于 417 / 2811.39。它低，不代表单请求慢，而是代表整轮 benchmark 里只有 417 条成功，剩下 1193 条失败，把总 wall time 拉长了。
- Total token throughput = 750.42 tok/s 不是 decode 速度，它等于“成功请求的输入 token goodput + 成功请求的输出 token goodput”。这次就是：
    - 输入 goodput: 1702144 / 2811.39 ≈ 605 tok/s
    - 输出 goodput: 407575 / 2811.39 ≈ 145 tok/s
    - 合起来约 750 tok/s

## 2. 怎么调优
