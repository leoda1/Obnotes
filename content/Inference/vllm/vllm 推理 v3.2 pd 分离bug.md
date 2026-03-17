## 0. 复现
> 问题描述：在使用 `P2pNcclConnector` 时，deepseek v3.2 模型的 pd 分离服务都正常 launch 后， requset 进来 prefill 侧报错，`AttributeError: 'NoneType' object has no attribute 'shape'`。

env：2 台 `8* h200`，docker images :`vllm:v0.13.0`。

 vllm commit：
```shell title="git log -1"
commit 72506c98349d6bcd32b4e33eec7b5513453c1502 (HEAD -> main, tag: v0.13.0, origin/releases/v0.13.0)
Author: Harry Mellor <19981378+hmellor@users.noreply.github.com>
Date:   Thu Dec 18 21:59:10 2025 +0000

    Check for truthy `rope_parameters` not the existence of it (#30983)
    
    Signed-off-by: Harry Mellor <19981378+hmellor@users.noreply.github.com>
    (cherry picked from commit 19c583398aec0ef2b9fe42ba020bc3c39e7e001f)
```
Code Path：/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p

### 启动 prefill

```shell title="prefill.sh"
# node1 上 proxy_ip 要改
export NCCL_SOCKET_IFNAME=bond0
export GLOO_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO
export NCCL_IB_HCA==mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
export NCCL_NVLS_ENABLE=0
export NCCL_IB_GID_INDEX=3
export VLLM_RPC_TIMEOUT=600000
export VLLM_ENGINE_ITERATION_TIMEOUT_S=600
unset PYTHONPATH
export PYTHONPATH=1
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
        --kv-transfer-config \
        '{"kv_connector":"P2pNcclConnector","kv_role":"kv_producer","kv_buffer_size":"1e10","kv_port":"21001","kv_connector_extra_config":{"proxy_ip":"10.254.11.136","proxy_port":"30002","http_port":"20001"}}' > prefill.log &
```

### 启动 decode

```shell  title="decode.sh"
# node2 上用 node1 的 proxy_ip
export NCCL_SOCKET_IFNAME=bond0
export GLOO_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO
export NCCL_IB_HCA==mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
export NCCL_NVLS_ENABLE=0
export NCCL_IB_GID_INDEX=3
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
        --gpu-memory-utilization 0.8 \
        --kv-transfer-config \
        '{"kv_connector":"P2pNcclConnector","kv_role":"kv_consumer","kv_buffer_size":"8e9","kv_port":"22001","kv_connector_extra_config":{"proxy_ip":"10.254.11.136","proxy_port":"30002","http_port":"20002"}}' > decode.log &
```

### 测试

```shell  title="test流程"
# 1. node1 启动 router 来管理 pd 
# router-nccl2.py 内需要适配 deepseek 的 message<-->prompt之间的编码，见下方代码
python3 router-nccl2.py --host 0.0.0.0 --http-port 10001 --discovery-port 30002

# 2. 打个 request
curl -s http://10.254.11.136:10001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "base_model",
    "messages": [
      {"role": "user", "content": "你好，简单介绍一下你自己"}
    ],
    "max_tokens": 128,
    "temperature": 0.2,
    "stream": false
  }'
```

```python title="router-nccl2.py"
import argparse
import copy
import importlib.util
import json
import os
import socket
import threading
import time
import uuid
from pathlib import Path
from typing import Any

import aiohttp
import msgpack
import zmq
from quart import Quart, jsonify, make_response, request


DEFAULT_HTTP_HOST = "0.0.0.0"
DEFAULT_HTTP_PORT = 10001
DEFAULT_DISCOVERY_HOST = "0.0.0.0"
DEFAULT_DISCOVERY_PORT = 30002
DEFAULT_INSTANCE_TTL_SECONDS = 5
AIOHTTP_TIMEOUT = aiohttp.ClientTimeout(total=6 * 60 * 60)

app = Quart(__name__)

count = 0
prefill_instances: dict[str, tuple[str, float]] = {}
decode_instances: dict[str, tuple[str, float]] = {}
prefill_cv = threading.Condition()
decode_cv = threading.Condition()
instance_ttl_seconds = DEFAULT_INSTANCE_TTL_SECONDS


def _load_deepseek_v32_encoding_module():
    module_path = (
        Path(__file__).resolve().parent
        / "vllm"
        / "tokenizers"
        / "deepseek_v32_encoding.py"
    )
    spec = importlib.util.spec_from_file_location(
        "_router_nccl_deepseek_v32_encoding",
        module_path,
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"Unable to load DeepSeek V3.2 encoder from {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_deepseek_v32_encoding = _load_deepseek_v32_encoding_module()
encode_messages = _deepseek_v32_encoding.encode_messages
parse_message_from_completion_text = (
    _deepseek_v32_encoding.parse_message_from_completion_text
)


def random_uuid() -> str:
    return uuid.uuid4().hex


def _prune_expired(instances: dict[str, tuple[str, float]]) -> None:
    now = time.time()
    expired = [key for key, (_, deadline) in instances.items() if deadline <= now]
    for key in expired:
        zmq_addr, deadline = instances.pop(key)
        print(f"remove instance http={key} zmq={zmq_addr} deadline={deadline}")


def _register_instance(role: str, http_address: str, zmq_address: str) -> None:
    global prefill_instances
    global decode_instances

    bucket = prefill_instances if role == "P" else decode_instances
    cv = prefill_cv if role == "P" else decode_cv
    deadline = time.time() + instance_ttl_seconds

    with cv:
        node = bucket.get(http_address)
        bucket[http_address] = (zmq_address, deadline)
        _prune_expired(bucket)
        if node is None:
            print(f"add instance role={role} http={http_address} zmq={zmq_address}")


def _listen_for_register(poller: zmq.Poller, router_socket: Any) -> None:
    while True:
        socks = dict(poller.poll())
        if router_socket not in socks:
            continue

        remote_address, message = router_socket.recv_multipart()
        data = msgpack.loads(message)
        role = data.get("type")
        http_address = data.get("http_address")
        zmq_address = data.get("zmq_address")

        if role not in {"P", "D"} or not http_address or not zmq_address:
            print(
                f"unexpected register remote={remote_address!r} data={data!r}",
            )
            continue

        _register_instance(role, http_address, zmq_address)


def start_service_discovery(hostname: str, port: int) -> threading.Thread:
    if not hostname:
        hostname = socket.gethostname()
    if port == 0:
        raise ValueError("discovery port cannot be 0")

    context = zmq.Context()
    router_socket = context.socket(zmq.ROUTER)
    router_socket.bind(f"tcp://{hostname}:{port}")

    poller = zmq.Poller()
    poller.register(router_socket, zmq.POLLIN)

    thread = threading.Thread(
        target=_listen_for_register,
        args=(poller, router_socket),
        daemon=True,
    )
    thread.start()
    print(f"service discovery listening on tcp://{hostname}:{port}")
    return thread


def _choose_instance(
    instances: dict[str, tuple[str, float]],
    cv: threading.Condition,
    idx: int,
) -> tuple[str, str] | None:
    with cv:
        _prune_expired(instances)
        if not instances:
            return None
        items = list(instances.items())
        http_addr, (zmq_addr, _) = items[idx % len(items)]
        return http_addr, zmq_addr


async def _post_request(
    url: str,
    data: dict[str, Any],
    request_id: str,
    auth_header: str | None,
    *,
    stream: bool = False,
):
    headers = {"X-Request-Id": request_id}
    if auth_header:
        headers["Authorization"] = auth_header
    elif os.environ.get("OPENAI_API_KEY"):
        headers["Authorization"] = f"Bearer {os.environ['OPENAI_API_KEY']}"

    if not stream:
        async with aiohttp.ClientSession(timeout=AIOHTTP_TIMEOUT) as session:
            async with session.post(url=url, json=data, headers=headers) as response:
                body = await response.read()
                return {
                    "ok": response.status == 200,
                    "status": response.status,
                    "body": body,
                    "content_type": response.headers.get(
                        "Content-Type",
                        "application/json",
                    ),
                }

    session = aiohttp.ClientSession(timeout=AIOHTTP_TIMEOUT)
    try:
        response = await session.post(url=url, json=data, headers=headers)
    except Exception:
        await session.close()
        raise

    content_type = response.headers.get(
        "Content-Type",
        "application/json",
    )
    if response.status != 200:
        try:
            body = await response.read()
            return {
                "ok": False,
                "status": response.status,
                "body": body,
                "content_type": content_type,
            }
        finally:
            response.close()
            await session.close()

    async def _stream():
        try:
            async for chunk in response.content.iter_chunked(8192):
                yield chunk
        finally:
            response.close()
            await session.close()

    return {
        "ok": True,
        "status": response.status,
        "stream": _stream(),
        "content_type": content_type,
    }


def _build_request_id(prefill_zmq_addr: str, decode_zmq_addr: str) -> str:
    return (
        f"___prefill_addr_{prefill_zmq_addr}___decode_addr_"
        f"{decode_zmq_addr}_{random_uuid()}"
    )


def _is_chat_request_path(path: str) -> bool:
    return path == "/v1/chat/completions"


def _error_response(message: str, status: int = 400):
    return jsonify({"error": message}), status


def _normalize_message_content(message: dict[str, Any]) -> dict[str, Any]:
    normalized = copy.deepcopy(message)
    content = normalized.get("content")
    if isinstance(content, list):
        text_parts: list[str] = []
        for part in content:
            if not isinstance(part, dict) or part.get("type") != "text":
                raise ValueError(
                    "Only text content is supported in /v1/chat/completions bridge"
                )
            text_parts.append(part.get("text", ""))
        normalized["content"] = "".join(text_parts)
    return normalized


def _get_thinking_mode(request_data: dict[str, Any]) -> str:
    if request_data.get("thinking") or request_data.get("enable_thinking"):
        return "thinking"

    reasoning_effort = request_data.get("reasoning_effort")
    include_reasoning = request_data.get("include_reasoning", True)
    if reasoning_effort not in (None, "none") and include_reasoning:
        return "thinking"

    return "chat"


def _build_chat_prompt(request_data: dict[str, Any]) -> tuple[str, str]:
    messages = request_data.get("messages")
    if not isinstance(messages, list) or len(messages) == 0:
        raise ValueError("`messages` must be a non-empty list")

    normalized_messages = [_normalize_message_content(msg) for msg in messages]
    thinking_mode = _get_thinking_mode(request_data)

    system_metadata: dict[str, Any] = {}
    if request_data.get("tools"):
        system_metadata["tools"] = copy.deepcopy(request_data["tools"])
    if request_data.get("response_format"):
        system_metadata["response_format"] = copy.deepcopy(
            request_data["response_format"]
        )
    if system_metadata:
        normalized_messages.insert(0, {"role": "system", **system_metadata})

    drop_thinking = normalized_messages[-1].get("role") in {"user", "developer"}
    prompt = encode_messages(
        normalized_messages,
        thinking_mode=thinking_mode,
        drop_thinking=drop_thinking,
    )
    return prompt, thinking_mode


def _build_completion_request_from_chat(
    request_data: dict[str, Any],
) -> tuple[dict[str, Any], str]:
    if request_data.get("stream"):
        raise ValueError(
            "`stream=true` is not supported for bridged /v1/chat/completions"
        )

    prompt, thinking_mode = _build_chat_prompt(request_data)

    completion_request = copy.deepcopy(request_data)
    for key in (
        "messages",
        "tools",
        "tool_choice",
        "response_format",
        "stream_options",
        "reasoning_effort",
        "include_reasoning",
        "parallel_tool_calls",
        "user",
        "chat_template",
        "chat_template_kwargs",
        "add_generation_prompt",
        "continue_final_message",
        "add_special_tokens",
        "documents",
        "thinking",
        "enable_thinking",
    ):
        completion_request.pop(key, None)

    max_completion_tokens = completion_request.pop("max_completion_tokens", None)
    if max_completion_tokens is not None and completion_request.get("max_tokens") is None:
        completion_request["max_tokens"] = max_completion_tokens

    completion_request["prompt"] = prompt
    completion_request["stream"] = False
    return completion_request, thinking_mode


def _materialize_tool_calls(tool_calls: list[dict[str, Any]]) -> list[dict[str, Any]]:
    materialized: list[dict[str, Any]] = []
    for tool_call in tool_calls:
        function = tool_call.get("function", {})
        materialized.append(
            {
                "id": f"call_{random_uuid()}",
                "type": tool_call.get("type", "function"),
                "function": {
                    "name": function.get("name"),
                    "arguments": function.get("arguments", ""),
                },
            }
        )
    return materialized


def _convert_completion_to_chat_response(
    completion_payload: dict[str, Any],
    thinking_mode: str,
    include_reasoning: bool,
) -> dict[str, Any]:
    choices: list[dict[str, Any]] = []
    for choice in completion_payload.get("choices", []):
        text = choice.get("text", "")
        try:
            parsed_message = parse_message_from_completion_text(text, thinking_mode)
        except Exception:
            parsed_message = {
                "role": "assistant",
                "content": text,
                "reasoning": "",
                "tool_calls": [],
            }

        tool_calls = _materialize_tool_calls(parsed_message.get("tool_calls", []))
        content = parsed_message.get("content")
        message: dict[str, Any] = {
            "role": "assistant",
            "content": content if content or not tool_calls else None,
        }
        if include_reasoning and parsed_message.get("reasoning"):
            message["reasoning"] = parsed_message["reasoning"]
        if tool_calls:
            message["tool_calls"] = tool_calls

        finish_reason = choice.get("finish_reason")
        if tool_calls and finish_reason in (None, "stop"):
            finish_reason = "tool_calls"

        choices.append(
            {
                "index": choice.get("index", 0),
                "message": message,
                "logprobs": None,
                "finish_reason": finish_reason or "stop",
                "stop_reason": choice.get("stop_reason"),
                "token_ids": choice.get("token_ids"),
            }
        )

    response_id = completion_payload.get("id", f"chatcmpl-{random_uuid()}")
    if isinstance(response_id, str) and response_id.startswith("cmpl-"):
        response_id = "chat" + response_id

    return {
        "id": response_id,
        "object": "chat.completion",
        "created": completion_payload.get("created", int(time.time())),
        "model": completion_payload.get("model"),
        "choices": choices,
        "usage": completion_payload.get("usage"),
        "service_tier": completion_payload.get("service_tier"),
        "system_fingerprint": completion_payload.get("system_fingerprint"),
        "prompt_logprobs": completion_payload.get("prompt_logprobs"),
        "prompt_token_ids": completion_payload.get("prompt_token_ids"),
        "kv_transfer_params": completion_payload.get("kv_transfer_params"),
    }


@app.route("/health", methods=["GET"])
async def health():
    with prefill_cv:
        _prune_expired(prefill_instances)
        prefill_count = len(prefill_instances)
    with decode_cv:
        _prune_expired(decode_instances)
        decode_count = len(decode_instances)
    return jsonify(
        {
            "status": "ok",
            "prefill_instances": prefill_count,
            "decode_instances": decode_count,
        }
    )


@app.route("/debug/instances", methods=["GET"])
async def debug_instances():
    with prefill_cv:
        _prune_expired(prefill_instances)
        prefills = dict(prefill_instances)
    with decode_cv:
        _prune_expired(decode_instances)
        decodes = dict(decode_instances)
    return jsonify({"prefill": prefills, "decode": decodes})


@app.route("/v1/completions", methods=["POST"])
@app.route("/v1/chat/completions", methods=["POST"])
async def handle_request():
    global count

    original_request_data = await request.get_json()
    auth_header = request.headers.get("Authorization")
    is_chat_request = _is_chat_request_path(request.path)
    include_reasoning = bool(original_request_data.get("include_reasoning", True))
    thinking_mode = "chat"

    if is_chat_request:
        try:
            request_data, thinking_mode = _build_completion_request_from_chat(
                original_request_data
            )
        except ValueError as exc:
            return _error_response(str(exc), 400)
    else:
        request_data = original_request_data
    upstream_path = "/v1/completions" if is_chat_request else request.path

    pair_index = count
    count += 1

    prefill = _choose_instance(prefill_instances, prefill_cv, pair_index)
    decode = _choose_instance(decode_instances, decode_cv, pair_index)

    if prefill is None:
        return (
            jsonify({"error": "no registered prefill instances"}),
            503,
        )
    if decode is None:
        return (
            jsonify({"error": "no registered decode instances"}),
            503,
        )

    prefill_addr, prefill_zmq_addr = prefill
    decode_addr, decode_zmq_addr = decode

    print(
        "route request "
        f"[HTTP:{prefill_addr}, ZMQ:{prefill_zmq_addr}] -> "
        f"[HTTP:{decode_addr}, ZMQ:{decode_zmq_addr}]"
    )

    prefill_request = dict(request_data)
    prefill_request["max_tokens"] = 1
    prefill_request["stream"] = False
    if "max_completion_tokens" in prefill_request:
        prefill_request["max_completion_tokens"] = 1
    should_stream = bool(request_data.get("stream"))

    request_id = _build_request_id(prefill_zmq_addr, decode_zmq_addr)

    prefill_result = await _post_request(
        f"http://{prefill_addr}{upstream_path}",
        prefill_request,
        request_id,
        auth_header,
        stream=False,
    )
    if not prefill_result["ok"]:
        return make_response(
            prefill_result["body"],
            prefill_result["status"],
            {"Content-Type": prefill_result["content_type"]},
        )

    decode_result = await _post_request(
        f"http://{decode_addr}{upstream_path}",
        request_data,
        request_id,
        auth_header,
        stream=should_stream,
    )
    if not decode_result["ok"]:
        return make_response(
            decode_result["body"],
            decode_result["status"],
            {"Content-Type": decode_result["content_type"]},
        )

    if is_chat_request:
        try:
            completion_payload = json.loads(decode_result["body"])
        except json.JSONDecodeError:
            return _error_response("decode instance returned non-JSON completion body", 502)

        chat_payload = _convert_completion_to_chat_response(
            completion_payload,
            thinking_mode,
            include_reasoning,
        )
        return await make_response(
            json.dumps(chat_payload, ensure_ascii=False),
            decode_result["status"],
            {"Content-Type": "application/json"},
        )

    if should_stream:
        response = await make_response(
            decode_result["stream"],
            decode_result["status"],
            {"Content-Type": decode_result["content_type"]},
        )
        response.timeout = None
        return response

    return await make_response(
        decode_result["body"],
        decode_result["status"],
        {"Content-Type": decode_result["content_type"]},
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=DEFAULT_HTTP_HOST)
    parser.add_argument("--http-port", type=int, default=DEFAULT_HTTP_PORT)
    parser.add_argument("--discovery-host", default=DEFAULT_DISCOVERY_HOST)
    parser.add_argument("--discovery-port", type=int, default=DEFAULT_DISCOVERY_PORT)
    parser.add_argument("--instance-ttl-seconds", type=int, default=5)
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    instance_ttl_seconds = args.instance_ttl_seconds
    discovery_thread = start_service_discovery(
        args.discovery_host,
        args.discovery_port,
    )
    app.run(host=args.host, port=args.http_port)
    discovery_thread.join()

```

### log

```shell title="报错日志"
[0;36m(Worker_TP7 pid=481423)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
[0;36m(Worker_TP7 pid=481423)[0;0m     "shape": tensor.shape,
[0;36m(Worker_TP7 pid=481423)[0;0m              ^^^^^^^^^^^^
[0;36m(Worker_TP7 pid=481423)[0;0m AttributeError: 'NoneType' object has no attribute 'shape'
qb-prod-gpu1415:481418:489090 [2] NCCL INFO ncclCommInitRank comm 0x7f87dc0112c0 rank 0 nranks 2 cudaDev 2 nvmlDev 2 busId 4c000 commId 0x9b03fe326577660f - Init COMPLETE
qb-prod-gpu1415:481418:489090 [2] NCCL INFO Init timings - ncclCommInitRank: rank 0 nranks 2 total 0.14 (kernels 0.00, alloc 0.00, bootstrap 0.00, allgathers 0.03, topo 0.07, graphs 0.00, connections 0.00, rest 0.02)
[0;36m(Worker_TP2 pid=481418)[0;0m INFO 03-16 00:50:11 [p2p_nccl_engine.py:226] 🤝ncclCommInitRank Success, 10.254.5.122:21003👉10.254.20.124:22003, MyRank:0
[0;36m(Worker_TP2 pid=481418)[0;0m Exception in thread Thread-3 (send_async):
[0;36m(Worker_TP2 pid=481418)[0;0m Traceback (most recent call last):
[0;36m(Worker_TP2 pid=481418)[0;0m   File "/usr/lib/python3.12/threading.py", line 1075, in _bootstrap_inner
[0;36m(Worker_TP2 pid=481418)[0;0m     self.run()
[0;36m(Worker_TP2 pid=481418)[0;0m   File "/usr/lib/python3.12/threading.py", line 1012, in run
[0;36m(Worker_TP2 pid=481418)[0;0m     self._target(*self._args, **self._kwargs)
[0;36m(Worker_TP2 pid=481418)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 484, in send_async
[0;36m(Worker_TP2 pid=481418)[0;0m     self.send_sync(item)
[0;36m(Worker_TP2 pid=481418)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
[0;36m(Worker_TP2 pid=481418)[0;0m     "shape": tensor.shape,
[0;36m(Worker_TP2 pid=481418)[0;0m              ^^^^^^^^^^^^
[0;36m(Worker_TP2 pid=481418)[0;0m AttributeError: 'NoneType' object has no attribute 'shape'
```

---
## 1. 分析

从 log 来看及源码来看，
* extract_kv_from_layer() 只处理两类 KV layout；如果都不匹配，就直接 return None。
- 但后面没有判空，直接把这个 None 传给 send_tensor()。
- send_tensor() 又把它塞进发送队列。
- send_sync() 假设它一定是 tensor，直接读 tensor.shape，于是线程崩了。

## 2. 解决方法

vLLM 中 KV cache tensor 只有两种 shape ，由 attention backend 决定：

| Backend 类型                                                  | ndim  | shape                                            | 索引方式                                    |
| ----------------------------------------------------------- | ----- | ------------------------------------------------ | --------------------------------------- |
| **MLA** (所有变体: FlashMLA, FlashMLA_Sparse, Triton_MLA, etc.) | **3** | (num_blocks, block_size, head_size)              | layer[block_ids, ...]                   |
| **FlashInfer** (非 MLA)                                      | **5** | (num_blocks, 2, block_size, num_heads, head_dim) | layer[block_ids, ...] (shape[1]==2)     |
| **FlashAttention** (非 MLA)                                  | **5** | (2, num_blocks, block_size, num_heads, head_dim) | layer[:, block_ids, ...] (shape[0]== 2) |
MLA 把 K 和 V **压缩为一个 latent 向量**`[kv_lora_rank + qk_rope_head_dim = 576]`，不需要分开存 K/V，所以只有 3 个维度。而传统 attention 需要分别存 K 和 V，所以有一个额外的 dim=2 维度（代表 K 和 V）。

原来通过 `isinstance(attn_metadata, MLACommonMetadata) or layer.shape[1] == 2` 来找出表格内前两种 case，结果 deepseek v3.2模型的 FLASHMLA_SPARSE 后端的 metadata 类型是 `FlashMLASparseMetadata`，不是
`MLACommonMetadata`，所以导致函数extract_kv_from_layer和inject_kv_into_layer会 return false；

我们这里通过将 `isinstance(attn_metadata, MLACommonMetadata)`  变为 `layer.ndim == 3` 来确保MLA 永远是 3D，与使用哪个 metadata 类型无关，因此改动对所有 MLA 变体都有效。

```diff title="diff"
diff --git a/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_connector.py b/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_connector.py
index 8f3a62d7bc..907b62b8d1 100644
--- a/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_connector.py
+++ b/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_connector.py
@@ -19,7 +19,7 @@ from vllm.distributed.kv_transfer.kv_connector.v1.p2p.p2p_nccl_engine import (
 )
 from vllm.distributed.parallel_state import get_world_group
 from vllm.logger import init_logger
-from vllm.v1.attention.backends.mla.common import MLACommonMetadata
+# from vllm.v1.attention.backends.mla.common import MLACommonMetadata
 from vllm.v1.core.sched.output import SchedulerOutput
 
 if TYPE_CHECKING:
@@ -161,7 +161,7 @@ class P2pNcclConnector(KVConnectorBase_V1):
                 None. The function modifies `layer` in-place.
             """
             if (
-                isinstance(attn_metadata, MLACommonMetadata) or layer.shape[1] == 2
+                layer.ndim == 3 or layer.shape[1] == 2
             ):  # MLA or FlashInfer
                 num_block = kv_cache.shape[0]
                 self.check_tensors_except_dim(layer, kv_cache, 0)
@@ -216,9 +216,14 @@ class P2pNcclConnector(KVConnectorBase_V1):
 
                 layer = kv_cache[forward_context.virtual_engine]
 
+                # Skip non-standard KV caches (e.g. V3.2 Indexer
+                # uint8 cache) that should not be transferred.
+                if layer.dtype == torch.uint8:
+                    continue
                 kv_cache = self.p2p_nccl_engine.recv_tensor(
                     request.request_id + "#" + layer_name, remote_address
                 )
+                
 
                 if kv_cache is None:
                     logger.warning("🚧kv_cache is None, %s", request.request_id)
@@ -285,7 +290,7 @@ class P2pNcclConnector(KVConnectorBase_V1):
                 Returns None if the layout is unsupported.
             """
             if (
-                isinstance(attn_metadata, MLACommonMetadata) or layer.shape[1] == 2
+                layer.ndim == 3 or layer.shape[1] == 2
             ):  # MLA or FlashInfer
                 return layer[block_ids, ...]
 
@@ -302,6 +307,15 @@ class P2pNcclConnector(KVConnectorBase_V1):
             remote_address = ip + ":" + str(port + self._rank)
 
             kv_cache = extract_kv_from_layer(kv_layer, request.block_ids)
+            if kv_cache is None:
+                logger.warning(
+                    "🚧Unsupported KV cache layout for layer %s, "
+                    "request_id:%s, shape:%s",
+                    layer_name,
+                    request_id,
+                    kv_layer.shape,
+                )
+                continue
             self.p2p_nccl_engine.send_tensor(
                 request_id + "#" + layer_name, kv_cache, remote_address
             )
@@ -528,4 +542,4 @@ class P2pNcclConnector(KVConnectorBase_V1):
             raise NotImplementedError(
                 "Currently, only symmetric TP is supported. Asymmetric TP, PP,"
                 "and others will be supported in future PRs."
-            )
+            )
\ No newline at end of file

```

## 3. 修复后测试

### before

```txt title='error.log'
[0;36m(Worker_TP6 pid=481422)[0;0m Traceback (most recent call last):
[0;36m(Worker_TP3 pid=481419)[0;0m [0;36m(Worker_TP6 pid=481422)[0;0m    File "/usr/lib/python3.12/threading.py", line 1075, in _bootstrap_inner
[0;36m(Worker_TP1 pid=481417)[0;0m  Exception in thread  Thread-3 (send_async) :
    [0;36m(Worker_TP1 pid=481417)[0;0m  Traceback (most recent call last):
  [0;36m(Worker_TP1 pid=481417)[0;0m    File "/usr/lib/python3.12/threading.py", line 1075, in _bootstrap_inner
 ^^^^^^^^^^^^
[0;36m(Worker_TP3 pid=481419)[0;0m AttributeError: 'NoneType' object has no attribute 'shape'[0;36m(Worker_TP5 pid=481421)[0;0m     self.run()

[0;36m(Worker_TP5 pid=481421)[0;0m   File "/usr/lib/python3.12/threading.py", line 1012, in run
[0;36m(Worker_TP4 pid=481420)[0;0m INFO 03-16 00:50:11 [p2p_nccl_engine.py:226] 🤝ncclCommInitRank Success, 10.254.5.122:21005👉10.254.20.124:22005, MyRank:0
[0;36m(Worker_TP6 pid=481422)[0;0m     self.run()
[0;36m(Worker_TP6 pid=481422)[0;0m   File "/usr/lib/python3.12/threading.py", line 1012, in run
[0;36m(Worker_TP5 pid=481421)[0;0m     self._target(*self._args, **self._kwargs)
[0;36m(Worker_TP1 pid=481417)[0;0m [0;36m(Worker_TP4 pid=481420)[0;0m     Exception in thread self.run()[0;36m(Worker_TP5 pid=481421)[0;0m Thread-3 (send_async)
  File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 484, in send_async
:
[0;36m(Worker_TP6 pid=481422)[0;0m     self._target(*self._args, **self._kwargs)[0;36m(Worker_TP4 pid=481420)[0;0m 
[0;36m(Worker_TP1 pid=481417)[0;0m Traceback (most recent call last):
  File "/usr/lib/python3.12/threading.py", line 1012, in run
[0;36m(Worker_TP4 pid=481420)[0;0m [0;36m(Worker_TP1 pid=481417)[0;0m   File "/usr/lib/python3.12/threading.py", line 1075, in _bootstrap_inner
    self._target(*self._args, **self._kwargs)
[0;36m(Worker_TP1 pid=481417)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 484, in send_async
[0;36m(Worker_TP6 pid=481422)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 484, in send_async
[0;36m(Worker_TP1 pid=481417)[0;0m     self.send_sync(item)
[0;36m(Worker_TP1 pid=481417)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
[0;36m(Worker_TP5 pid=481421)[0;0m [0;36m(Worker_TP4 pid=481420)[0;0m         self.send_sync(item)self.run()

[0;36m(Worker_TP6 pid=481422)[0;0m     self.send_sync(item)
[0;36m(Worker_TP4 pid=481420)[0;0m [0;36m(Worker_TP5 pid=481421)[0;0m   File "/usr/lib/python3.12/threading.py", line 1012, in run
  File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
[0;36m(Worker_TP1 pid=481417)[0;0m [0;36m(Worker_TP6 pid=481422)[0;0m       File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
"shape": tensor.shape,qb-prod-gpu1415:481418:489090 [2] NCCL INFO comm 0x7f87dc0112c0 rank 0 nRanks 2 nNodes 2 localRanks 1 localRank 0 MNNVL 0

[0;36m(Worker_TP1 pid=481417)[0;0m qb-prod-gpu1415:481418:489090 [2] NCCL INFO Channel 00/02 : 0 1
 qb-prod-gpu1415:481418:489090 [2] NCCL INFO Channel 01/02 : 0 1
 qb-prod-gpu1415:481418:489090 [2] NCCL INFO Trees [0] 1/-1/-1->0->-1 [1] -1/-1/-1->0->1
 [0;36m(Worker_TP4 pid=481420)[0;0m  qb-prod-gpu1415:481418:489090 [2] NCCL INFO P2P Chunksize set to 131072
     qb-prod-gpu1415:481418:489090 [2] NCCL INFO Check P2P Type isAllDirectP2p 0 directMode 0
self._target(*self._args, **self._kwargs) 
[0;36m(Worker_TP6 pid=481422)[0;0m       [0;36m(Worker_TP5 pid=481421)[0;0m "shape": tensor.shape, qb-prod-gpu1415:481423:489082 [7] NCCL INFO ncclCommInitRank comm 0x7f67440112c0 rank 0 nranks 2 cudaDev 7 nvmlDev 7 busId db000 commId 0xf9e959292a59f371 - Init COMPLETE
[0;36m(Worker_TP4 pid=481420)[0;0m     
   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 484, in send_async
"shape": tensor.shape,qb-prod-gpu1415:481423:489082 [7] NCCL INFO Init timings - ncclCommInitRank: rank 0 nranks 2 total 0.11 (kernels 0.00, alloc 0.00, bootstrap 0.00, allgathers 0.01, topo 0.04, graphs 0.00, connections 0.04, rest 0.02)
 [0;36m(Worker_TP6 pid=481422)[0;0m 
   [0;36m(Worker_TP5 pid=481421)[0;0m  ^  ^  qb-prod-gpu1415:481416:489081 [0] NCCL INFO ncclCommInitRank comm 0x7fb50c0112d0 rank 0 nranks 2 cudaDev 0 nvmlDev 0 busId 19000 commId 0x251741b6b0ad969e - Init COMPLETE
^  ^ qb-prod-gpu1415:481416:489081 [0] NCCL INFO Init timings - ncclCommInitRank: rank 0 nranks 2 total 0.11 (kernels 0.00, alloc 0.00, bootstrap 0.00, allgathers 0.01, topo 0.06, graphs 0.00, connections 0.01, rest 0.02)
 ^[0;36m(Worker_TP4 pid=481420)[0;0m   ^      ^self.send_sync(item)[0;36m(Worker_TP7 pid=481423)[0;0m  ^
 INFO 03-16 00:50:11 [p2p_nccl_engine.py:226] 🤝ncclCommInitRank Success, 10.254.5.122:21008👉10.254.20.124:22008, MyRank:0
 ^[0;36m(Worker_TP4 pid=481420)[0;0m   ^  File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
  ^  ^[0;36m(Worker_TP7 pid=481423)[0;0m ^ 
Exception in thread ^ [0;36m(Worker_TP1 pid=481417)[0;0m AttributeErrorThread-3 (send_async)^ : :
^[0;36m(Worker_TP4 pid=481420)[0;0m ^[0;36m(Worker_TP0 pid=481416)[0;0m 'NoneType' object has no attribute 'shape'^[0;36m(Worker_TP7 pid=481423)[0;0m     ^qb-prod-gpu1415:481418:574973 [2] NCCL INFO [Proxy Service] Device 2 CPU core 140
INFO 03-16 00:50:11 [p2p_nccl_engine.py:226] 🤝ncclCommInitRank Success, 10.254.5.122:21001👉10.254.20.124:22001, MyRank:0
^^^^^^^
[0;36m(Worker_TP6 pid=481422)[0;0m AttributeError: 'NoneType' object has no attribute 'shape'[0;36m(Worker_TP0 pid=481416)[0;0m 
Exception in thread Thread-4 (send_async):
qb-prod-gpu1415:481418:574974 [2] NCCL INFO [Proxy Service UDS] Device 2 CPU core 141
[0;36m(Worker_TP0 pid=481416)[0;0m Traceback (most recent call last):
[0;36m(Worker_TP0 pid=481416)[0;0m   File "/usr/lib/python3.12/threading.py", line 1075, in _bootstrap_inner
Traceback (most recent call last):
[0;36m(Worker_TP0 pid=481416)[0;0m     self.run()
[0;36m(Worker_TP7 pid=481423)[0;0m   File "/usr/lib/python3.12/threading.py", line 1075, in _bootstrap_inner
[0;36m(Worker_TP0 pid=481416)[0;0m   File "/usr/lib/python3.12/threading.py", line 1012, in run
"shape": tensor.shape,[0;36m(Worker_TP0 pid=481416)[0;0m     self._target(*self._args, **self._kwargs)
^
qb-prod-gpu1415:481418:489090 [2] NCCL INFO threadThresholds 8/8/64 | 16/8/64 | 512 | 512
[0;36m(Worker_TP0 pid=481416)[0;0m ^qb-prod-gpu1415:481418:489090 [2] NCCL INFO 2 coll channels, 2 collnet channels, 0 nvls channels, 2 p2p channels, 2 p2p channels per peer
  File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 484, in send_async
[0;36m(Worker_TP4 pid=481420)[0;0m ^ ^ [0;36m(Worker_TP7 pid=481423)[0;0m ^     ^
 self.run()^ 
^ [0;36m(Worker_TP0 pid=481416)[0;0m ^     [0;36m(Worker_TP7 pid=481423)[0;0m ^ self.send_sync(item)  File "/usr/lib/python3.12/threading.py", line 1012, in run

 
 [0;36m(Worker_TP5 pid=481421)[0;0m  AttributeError[0;36m(Worker_TP0 pid=481416)[0;0m  :   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
 'NoneType' object has no attribute 'shape'^^^qb-prod-gpu1415:481418:489090 [2] NCCL INFO CC Off, workFifoBytes 1048576
[0;36m(Worker_TP7 pid=481423)[0;0m ^    
^self._target(*self._args, **self._kwargs)^
^^^^^^
[0;36m(Worker_TP7 pid=481423)[0;0m [0;36m(Worker_TP4 pid=481420)[0;0m [0;36m(Worker_TP0 pid=481416)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 484, in send_async
AttributeError    : "shape": tensor.shape,'NoneType' object has no attribute 'shape'
[0;36m(Worker_TP0 pid=481416)[0;0m            
  ^^^^^^^^^^^^
[0;36m(Worker_TP0 pid=481416)[0;0m AttributeError: 'NoneType' object has no attribute 'shape'[0;36m(Worker_TP7 pid=481423)[0;0m     self.send_sync(item)

[0;36m(Worker_TP7 pid=481423)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
[0;36m(Worker_TP7 pid=481423)[0;0m     "shape": tensor.shape,
[0;36m(Worker_TP7 pid=481423)[0;0m              ^^^^^^^^^^^^
[0;36m(Worker_TP7 pid=481423)[0;0m AttributeError: 'NoneType' object has no attribute 'shape'
qb-prod-gpu1415:481418:489090 [2] NCCL INFO ncclCommInitRank comm 0x7f87dc0112c0 rank 0 nranks 2 cudaDev 2 nvmlDev 2 busId 4c000 commId 0x9b03fe326577660f - Init COMPLETE
qb-prod-gpu1415:481418:489090 [2] NCCL INFO Init timings - ncclCommInitRank: rank 0 nranks 2 total 0.14 (kernels 0.00, alloc 0.00, bootstrap 0.00, allgathers 0.03, topo 0.07, graphs 0.00, connections 0.00, rest 0.02)
[0;36m(Worker_TP2 pid=481418)[0;0m INFO 03-16 00:50:11 [p2p_nccl_engine.py:226] 🤝ncclCommInitRank Success, 10.254.5.122:21003👉10.254.20.124:22003, MyRank:0
[0;36m(Worker_TP2 pid=481418)[0;0m Exception in thread Thread-3 (send_async):
[0;36m(Worker_TP2 pid=481418)[0;0m Traceback (most recent call last):
[0;36m(Worker_TP2 pid=481418)[0;0m   File "/usr/lib/python3.12/threading.py", line 1075, in _bootstrap_inner
[0;36m(Worker_TP2 pid=481418)[0;0m     self.run()
[0;36m(Worker_TP2 pid=481418)[0;0m   File "/usr/lib/python3.12/threading.py", line 1012, in run
[0;36m(Worker_TP2 pid=481418)[0;0m     self._target(*self._args, **self._kwargs)
[0;36m(Worker_TP2 pid=481418)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 484, in send_async
[0;36m(Worker_TP2 pid=481418)[0;0m     self.send_sync(item)
[0;36m(Worker_TP2 pid=481418)[0;0m   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/kv_transfer/kv_connector/v1/p2p/p2p_nccl_engine.py", line 513, in send_sync
[0;36m(Worker_TP2 pid=481418)[0;0m     "shape": tensor.shape,
[0;36m(Worker_TP2 pid=481418)[0;0m              ^^^^^^^^^^^^
[0;36m(Worker_TP2 pid=481418)[0;0m AttributeError: 'NoneType' object has no attribute 'shape'
[0;36m(EngineCore_DP0 pid=481282)[0;0m INFO 03-16 00:51:10 [shm_broadcast.py:542] No available shared memory broadcast block found in 60 seconds. This typically happens when some processes are hanging or doing some time-consuming work (e.g. compilation, weight/kv cache quantization).
[0;36m(EngineCore_DP0 pid=481282)[0;0m INFO 03-16 00:52:10 [shm_broadcast.py:542] No available shared memory broadcast block found in 60 seconds. This typically happens when some processes are hanging or doing some time-consuming work (e.g. compilation, weight/kv cache quantization).
[0;36m(EngineCore_DP0 pid=481282)[0;0m INFO 03-16 00:53:10 [shm_broadcast.py:542] No available shared memory broadcast block found in 60 seconds. This typically happens when some processes are hanging or doing some time-consuming work (e.g. compilation, weight/kv cache quantization).
[0;36m(EngineCore_DP0 pid=481282)[0;0m INFO 03-16 00:54:10 [shm_broadcast.py:542] No available shared memory broadcast block found in 60 seconds. This typically happens when some processes are hanging or doing some time-consuming work (e.g. compilation, weight/kv cache quantization).
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [dump_input.py:72] Dumping input data for V1 LLM engine (v0.13.0) with config: model='/inspire/hdd/global_public/public_models/deepseek-ai/DeepSeek-V3.2/', speculative_config=None, tokenizer='/inspire/hdd/global_public/public_models/deepseek-ai/DeepSeek-V3.2/', skip_tokenizer_init=False, tokenizer_mode=auto, revision=None, tokenizer_revision=None, trust_remote_code=True, dtype=torch.bfloat16, max_seq_len=10000, download_dir=None, load_format=auto, tensor_parallel_size=8, pipeline_parallel_size=1, data_parallel_size=1, disable_custom_all_reduce=False, quantization=fp8, enforce_eager=False, kv_cache_dtype=auto, device_config=cuda, structured_outputs_config=StructuredOutputsConfig(backend='auto', disable_fallback=False, disable_any_whitespace=False, disable_additional_properties=False, reasoning_parser='', reasoning_parser_plugin='', enable_in_reasoning=False), observability_config=ObservabilityConfig(show_hidden_metrics_for_version=None, otlp_traces_endpoint=None, collect_detailed_traces=None, kv_cache_metrics=False, kv_cache_metrics_sample=0.01, cudagraph_metrics=False, enable_layerwise_nvtx_tracing=False), seed=1024, served_model_name=base_model, enable_prefix_caching=True, enable_chunked_prefill=True, pooler_config=None, compilation_config={'level': None, 'mode': <CompilationMode.VLLM_COMPILE: 3>, 'debug_dump_path': None, 'cache_dir': '', 'compile_cache_save_format': 'binary', 'backend': 'inductor', 'custom_ops': ['+quant_fp8', 'none', '+quant_fp8', '+quant_fp8', '+quant_fp8'], 'splitting_ops': ['vllm::unified_attention', 'vllm::unified_attention_with_output', 'vllm::unified_mla_attention', 'vllm::unified_mla_attention_with_output', 'vllm::mamba_mixer2', 'vllm::mamba_mixer', 'vllm::short_conv', 'vllm::linear_attention', 'vllm::plamo2_mamba_mixer', 'vllm::gdn_attention_core', 'vllm::kda_attention', 'vllm::sparse_attn_indexer'], 'compile_mm_encoder': False, 'compile_sizes': [], 'compile_ranges_split_points': [10000], 'inductor_compile_config': {'enable_auto_functionalized_v2': False, 'combo_kernels': True, 'benchmark_combo_kernel': True}, 'inductor_passes': {}, 'cudagraph_mode': <CUDAGraphMode.FULL_AND_PIECEWISE: (2, 1)>, 'cudagraph_num_of_warmups': 1, 'cudagraph_capture_sizes': [1, 2, 4, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128, 136, 144, 152, 160, 168, 176, 184, 192, 200, 208, 216, 224, 232, 240, 248, 256, 272, 288, 304, 320, 336, 352, 368, 384, 400, 416, 432, 448, 464, 480, 496, 512], 'cudagraph_copy_inputs': False, 'cudagraph_specialize_lora': True, 'use_inductor_graph_partition': False, 'pass_config': {'fuse_norm_quant': True, 'fuse_act_quant': True, 'fuse_attn_quant': False, 'eliminate_noops': True, 'enable_sp': False, 'fuse_gemm_comms': False, 'fuse_allreduce_rms': False}, 'max_cudagraph_capture_size': 512, 'dynamic_shapes_config': {'type': <DynamicShapesType.BACKED: 'backed'>, 'evaluate_guards': False}, 'local_cache_dir': None}, 
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [dump_input.py:79] Dumping scheduler output for model execution: SchedulerOutput(scheduled_new_reqs=[NewRequestData(req_id=cmpl-___prefill_addr_10.254.5.122:21001___decode_addr_10.254.20.124:22001_811616018cef4145af55ff4d21ef9a5c-0,prompt_token_ids_len=6,mm_features=[],sampling_params=SamplingParams(n=1, presence_penalty=0.0, frequency_penalty=0.0, repetition_penalty=1.0, temperature=0.7, top_p=0.95, top_k=0, min_p=0.0, seed=None, stop=[], stop_token_ids=[], bad_words=[], include_stop_str_in_output=False, ignore_eos=False, max_tokens=1, min_tokens=0, logprobs=None, prompt_logprobs=None, skip_special_tokens=True, spaces_between_special_tokens=True, truncate_prompt_tokens=None, structured_outputs=None, extra_args=None),block_ids=([1],),num_computed_tokens=0,lora_request=None,prompt_embeds_shape=None)], scheduled_cached_reqs=CachedRequestData(req_ids=[], resumed_req_ids=[], new_token_ids=[], all_token_ids={}, new_block_ids=[], num_computed_tokens=[], num_output_tokens=[]), num_scheduled_tokens={cmpl-___prefill_addr_10.254.5.122:21001___decode_addr_10.254.20.124:22001_811616018cef4145af55ff4d21ef9a5c-0: 6}, total_num_scheduled_tokens=6, scheduled_spec_decode_tokens={}, scheduled_encoder_inputs={}, num_common_prefix_blocks=[1], finished_req_ids=[], free_encoder_mm_hashes=[], preempted_req_ids=[], pending_structured_output_tokens=false, kv_connector_metadata=P2pNcclConnectorMetadata(requests=[ReqMeta(request_id='cmpl-___prefill_addr_10.254.5.122:21001___decode_addr_10.254.20.124:22001_811616018cef4145af55ff4d21ef9a5c-0', block_ids=Tensor(shape=torch.Size([1]), device=cpu,dtype=torch.int64), num_tokens=6)]), ec_connector_metadata=null)
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [dump_input.py:81] Dumping scheduler stats: SchedulerStats(num_running_reqs=1, num_waiting_reqs=0, step_counter=0, current_wave=0, kv_cache_usage=0.00016906170752328809, prefix_cache_stats=PrefixCacheStats(reset=False, requests=1, queries=6, hits=0, preempted_requests=0, preempted_queries=0, preempted_hits=0), connector_prefix_cache_stats=PrefixCacheStats(reset=False, requests=1, queries=6, hits=0, preempted_requests=0, preempted_queries=0, preempted_hits=0), kv_cache_eviction_events=[], spec_decoding_stats=None, kv_connector_stats=None, waiting_lora_adapters={}, running_lora_adapters={}, cudagraph_stats=None)
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868] EngineCore encountered a fatal error.
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868] Traceback (most recent call last):
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/executor/multiproc_executor.py", line 336, in get_response
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     status, result = mq.dequeue(
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]                      ^^^^^^^^^^^
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/device_communicators/shm_broadcast.py", line 616, in dequeue
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     with self.acquire_read(timeout, cancel, indefinite) as buf:
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/lib/python3.12/contextlib.py", line 137, in __enter__
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     return next(self.gen)
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]            ^^^^^^^^^^^^^^
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/distributed/device_communicators/shm_broadcast.py", line 536, in acquire_read
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     raise TimeoutError
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868] TimeoutError
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868] 
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868] The above exception was the direct cause of the following exception:
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868] 
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868] Traceback (most recent call last):
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/core.py", line 859, in run_engine_core
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     engine_core.run_busy_loop()
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/core.py", line 886, in run_busy_loop
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     self._process_engine_step()
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/core.py", line 919, in _process_engine_step
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     outputs, model_executed = self.step_fn()
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]                               ^^^^^^^^^^^^^^
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/core.py", line 351, in step
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     model_output = future.result()
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]                    ^^^^^^^^^^^^^^^
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/executor/multiproc_executor.py", line 80, in result
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     return super().result()
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]            ^^^^^^^^^^^^^^^^
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/lib/python3.12/concurrent/futures/_base.py", line 449, in result
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     return self.__get_result()
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]            ^^^^^^^^^^^^^^^^^^^
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/lib/python3.12/concurrent/futures/_base.py", line 401, in __get_result
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     raise self._exception
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/executor/multiproc_executor.py", line 84, in wait_for_response
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     response = self.aggregate(get_response())
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]                               ^^^^^^^^^^^^^^
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/executor/multiproc_executor.py", line 340, in get_response
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868]     raise TimeoutError(f"RPC call to {method} timed out.") from e
[0;36m(EngineCore_DP0 pid=481282)[0;0m ERROR 03-16 00:55:10 [core.py:868] TimeoutError: RPC call to execute_model timed out.
[0;36m(APIServer pid=480795)[0;0m ERROR 03-16 00:55:10 [async_llm.py:538] AsyncLLM output_handler failed.
[0;36m(APIServer pid=480795)[0;0m ERROR 03-16 00:55:10 [async_llm.py:538] Traceback (most recent call last):
[0;36m(APIServer pid=480795)[0;0m ERROR 03-16 00:55:10 [async_llm.py:538]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/async_llm.py", line 490, in output_handler
[0;36m(APIServer pid=480795)[0;0m ERROR 03-16 00:55:10 [async_llm.py:538]     outputs = await engine_core.get_output_async()
[0;36m(APIServer pid=480795)[0;0m ERROR 03-16 00:55:10 [async_llm.py:538]               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[0;36m(APIServer pid=480795)[0;0m ERROR 03-16 00:55:10 [async_llm.py:538]   File "/usr/local/lib/python3.12/dist-packages/vllm/v1/engine/core_client.py", line 895, in get_output_async
[0;36m(APIServer pid=480795)[0;0m ERROR 03-16 00:55:10 [async_llm.py:538]     raise self._format_exception(outputs) from None
[0;36m(APIServer pid=480795)[0;0m ERROR 03-16 00:55:10 [async_llm.py:538] vllm.v1.engine.exceptions.EngineDeadError: EngineCore encountered an issue. See stack trace (above) for the root cause.
[0;36m(APIServer pid=480795)[0;0m INFO:     10.254.5.122:45440 - "POST /v1/completions HTTP/1.1" 500 Internal Server Error
[0;36m(Worker_TP0 pid=481416)[0;0m INFO 03-16 00:55:10 [multiproc_executor.py:709] Parent process exited, terminating worker
[0;36m(Worker_TP2 pid=481418)[0;0m [0;36m(Worker_TP5 pid=481421)[0;0m [0;36m(Worker_TP7 pid=481423)[0;0m INFO 03-16 00:55:10 [multiproc_executor.py:709] Parent process exited, terminating worker
INFO 03-16 00:55:10 [multiproc_executor.py:709] Parent process exited, terminating worker
[0;36m(Worker_TP3 pid=481419)[0;0m [0;36m(Worker_TP6 pid=481422)[0;0m INFO 03-16 00:55:10 [multiproc_executor.py:709] Parent process exited, terminating worker
INFO 03-16 00:55:10 [multiproc_executor.py:709] Parent process exited, terminating worker
[0;36m(Worker_TP4 pid=481420)[0;0m INFO 03-16 00:55:10 [multiproc_executor.py:709] Parent process exited, terminating worker
INFO 03-16 00:55:10 [multiproc_executor.py:709] Parent process exited, terminating worker
[0;36m(Worker_TP1 pid=481417)[0;0m INFO 03-16 00:55:10 [multiproc_executor.py:709] Parent process exited, terminating worker
qb-prod-gpu1415:481420:481420 [4] NCCL INFO comm 0x3db5a550 rank 4 nranks 8 cudaDev 4 busId 9b000 - Destroy COMPLETE
qb-prod-gpu1415:481421:481421 [5] NCCL INFO comm 0x3c776550 rank 5 nranks 8 cudaDev 5 busId bb000 - Destroy COMPLETE
qb-prod-gpu1415:481422:481422 [6] NCCL INFO comm 0x40694d10 rank 6 nranks 8 cudaDev 6 busId cb000 - Destroy COMPLETE
qb-prod-gpu1415:481418:481418 [2] NCCL INFO comm 0x3ce6fa40 rank 2 nranks 8 cudaDev 2 busId 4c000 - Destroy COMPLETE
qb-prod-gpu1415:481423:481423 [7] NCCL INFO comm 0x3c686b70 rank 7 nranks 8 cudaDev 7 busId db000 - Destroy COMPLETE
qb-prod-gpu1415:481417:481417 [1] NCCL INFO comm 0x3da30040 rank 1 nranks 8 cudaDev 1 busId 3b000 - Destroy COMPLETE
qb-prod-gpu1415:481419:481419 [3] NCCL INFO comm 0x40e31570 rank 3 nranks 8 cudaDev 3 busId 5d000 - Destroy COMPLETE
qb-prod-gpu1415:481416:481416 [0] NCCL INFO comm 0x3c6327d0 rank 0 nranks 8 cudaDev 0 busId 19000 - Destroy COMPLETE
[0;36m(APIServer pid=480795)[0;0m INFO:     Shutting down
[0;36m(APIServer pid=480795)[0;0m INFO:     Waiting for application shutdown.
[0;36m(APIServer pid=480795)[0;0m INFO:     Application shutdown complete.
[0;36m(APIServer pid=480795)[0;0m INFO:     Finished server process [480795]
/usr/lib/python3.12/multiprocessing/resource_tracker.py:279: UserWarning: resource_tracker: There appear to be 1 leaked shared_memory objects to clean up at shutdown
  warnings.warn('resource_tracker: There appear to be %d '
```

### after

![79ac4a70bb193d2a8c1b6a258ae141bb.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20260317162822139.png)