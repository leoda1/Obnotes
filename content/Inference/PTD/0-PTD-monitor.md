## 1. 目标

系统统一采集 Prefill、Decode 和 KV Cache 传输三类数据，并在 Grafana 中展示原始值及其相对时间的导数，得到三条当前处理速率（req/s）：

1. Prefill req/s；
2. Decode req/s；
3. KV Cache 传输等价 req/s。

Prometheus 默认每 1 秒采集一次。所有速率均由相邻采样点的实际数值差除以实际时间差得到，不使用固定执行耗时替代墙钟时间。

## 2. 系统输入假设

输入流量由用户保证：

- 请求量足够，系统处于持续工作状态；
- 同一轮测试中的输入长度均匀且固定为 8K 或 16K；
- 同一轮测试使用同一个模型和同一种 KV Cache 数据类型。

因此，同一轮测试可使用固定的单请求 KV Cache 字节数，将 KV Cache bytes/s 换算为 req/s。

## 3. 三类数据采集

### 3.1 Prefill

Prefill 侧采集两类数据：**队列/批次占用**（瞬时 gauge，说明并发与背压）和**完成速率**（单调 Counter，用于求导得到 req/s）。

vLLM（`vllm:` 前缀，实例按 `instance=~"prefill.*"` 区分）：

| 类别 | 指标 | 含义 |
| --- | --- | --- |
| 占用 | `vllm:num_requests_running` | 当前在 running batch 中的请求数 |
| 占用 | `vllm:num_requests_waiting` | 当前在 waiting queue 中排队的请求数 |
| 吞吐 | `vllm:prompt_tokens_total` | 累计 prompt token 数，求导得到 Prefill input tok/s |
| 完成 | `vllm:request_success_total{finished_reason!~"abort\|error"}` | 累计成功完成请求数，求导得到 Prefill req/s |
| 其他 | `vllm:kv_cache_usage_perc`、`vllm:time_to_first_token_seconds_bucket`、`vllm:request_prefill_time_seconds_*`、`vllm:request_queue_time_seconds_*`、`vllm:prefix_cache_hits_total` / `vllm:prefix_cache_queries_total`、`vllm:num_preemptions_total` | KV 占用、TTFT 分位、分阶段耗时、前缀缓存命中率、抢占累计数 |

SGLang（`sglang:` 前缀，实例按 `engine_type="prefill"` 区分）：

| 类别 | 指标 | 含义 |
| --- | --- | --- |
| 占用 | `sglang:num_running_reqs` | 当前在 running batch 中的请求数 |
| 占用 | `sglang:num_queue_reqs` | 当前 waiting queue 深度 |
| 占用 | `sglang:num_prefill_bootstrap_queue_reqs` | P/D 握手阶段（bootstrap queue）请求数 |
| 占用 | `sglang:num_prefill_inflight_queue_reqs` | KV 已算完、正在向 Decode 传输中（inflight queue）的请求数 |
| 吞吐 | `sglang:prompt_tokens_total` | 累计 prompt token 数，求导得到 Prefill input tok/s |
| 完成 | `sglang:num_requests_total` | 累计请求数，求导得到 Prefill req/s |
| 其他 | `sglang:kv_used_tokens`、`sglang:kv_evictable_tokens`、`sglang:max_total_num_tokens`、`sglang:cache_hit_rate`、`sglang:num_aborted_requests_total`、`sglang:num_retracted_reqs`、`sglang:num_bootstrap_failed_reqs_total` | KV 占用（Occupied / Active 两条）、前缀缓存命中率、异常请求计数 |

其中 SGLang 的 bootstrap queue 和 inflight queue 是 P/D 分离特有的两个中间队列：bootstrap queue 堆积说明 Prefill 在等 Decode 侧完成握手/预分配，inflight queue 堆积说明算力已经算完但 KV 传输成为瓶颈。

### 3.2 Decode

Decode 侧同样区分占用与完成速率。

vLLM（`instance=~"decode.*"`）：

| 类别 | 指标 | 含义 |
| --- | --- | --- |
| 占用 | `vllm:num_requests_running` | 当前在 running batch 中解码的请求数 |
| 占用 | `vllm:num_requests_waiting` | 当前排队等待解码的请求数 |
| 吞吐 | `vllm:generation_tokens_total` | 累计生成 token 数，求导得到 Decode output tok/s |
| 完成 | `vllm:request_success_total{finished_reason!~"abort\|error"}` | 累计成功完成请求数，求导得到 Decode req/s |
| 其他 | `vllm:kv_cache_usage_perc`、`vllm:inter_token_latency_seconds_bucket`、`vllm:e2e_request_latency_seconds_bucket`、`vllm:request_decode_time_seconds_*` | KV 占用、ITL 分位、端到端时延分位、解码阶段平均耗时 |

SGLang（`engine_type="decode"`）：

| 类别 | 指标 | 含义 |
| --- | --- | --- |
| 占用 | `sglang:num_running_reqs` | 当前在 running batch 中解码的请求数 |
| 占用 | `sglang:num_queue_reqs` | 当前 waiting queue 深度 |
| 占用 | `sglang:num_decode_prealloc_queue_reqs` | 正在为接收 KV 预分配显存（prealloc queue）的请求数 |
| 占用 | `sglang:num_decode_transfer_queue_reqs` | 正在接收 Prefill KV（transfer queue）的请求数 |
| 吞吐 | `sglang:generation_tokens_total` | 累计生成 token 数，求导得到 Decode output tok/s |
| 完成 | `sglang:num_requests_total` | 累计请求数，求导得到 Decode req/s |
| 其他 | `sglang:time_to_first_token_seconds_bucket`、`sglang:inter_token_latency_seconds_bucket`、`sglang:e2e_request_latency_seconds_bucket`、`sglang:kv_used_tokens` / `sglang:kv_evictable_tokens` / `sglang:max_total_num_tokens` | TTFT / ITL / E2E 分位、KV 占用 |

在 SGLang 的 P/D 部署里，TTFT 直方图由 Decode 侧在产出首 token 时上报，Prefill 侧的抓取结果中不含 TTFT 样本，因此 TTFT 面板统一取 `engine_type="decode"`。prealloc queue 与 transfer queue 与 Prefill 侧的 bootstrap / inflight queue 一一对应，两侧对照即可判断卡点在预分配还是在链路传输。

**注意**：`running` / `waiting` 及各中间队列都是瞬时 gauge，只用于解释并发与背压，**不能对其求导当作 req/s**；三条 req/s 曲线全部来自单调 Counter（vLLM 用 `vllm:request_success_total`，SGLang 用 `sglang:num_requests_total`，KV 用 `flagcx_total_bytes_transferred_total`）。

### 3.3 KV Cache 传输

KV Cache 传输使用 `FlagCXKVConnectorStats` 统计实际完成拷贝的 bytes：

- 所有传输线程都把本次完成的拷贝字节数写入 `FlagCXKVConnectorStats`；
- 单个 engine 汇总其所有线程的 bytes；
- 监控层再汇总所有 engine 的 bytes；
- 最终导出全局累计 KV Cache 传输字节数 Counter。

统计对象是实际 KV Cache payload bytes，不再使用每次传输的带宽均值做二次推算。

## 4. 调用与聚合逻辑

```text
Prefill scheduler
  └─ 读取 running 当前请求数
       └─ Prometheus 每 1s 采集
            └─ Grafana 对 running 按时间求导 → Prefill req/s

Decode scheduler
  └─ 读取 running 当前请求数
       └─ Prometheus 每 1s 采集
            └─ Grafana 对 running 按时间求导 → Decode req/s

KV Cache 传输线程
  └─ 完成一次 KV Cache 拷贝
       └─ FlagCXKVConnectorStats 累加本次 bytes
            └─ 汇总单个 engine 的所有线程
                 └─ 汇总所有 engine
                      └─ Prometheus 每 1s 采集全局累计 bytes
                           └─ Grafana 按时间求导 → bytes/s
                                └─ 除以单请求 KV Cache bytes → KV req/s
```

## 5. 单请求 KV Cache 字节数

一个请求的 KV Cache 字节数按模型参数和输入长度计算：

$$
B_{request}
= N_{kv\_head}
\times N_{layer}
\times 2
\times H_{head}
\times S
\times B_{element}
$$

其中：

- $N_{kv\_head}$：模型 KV head 数；
- $N_{layer}$：模型层数；
- $2$：Key 和 Value 两份 Cache；
- $H_{head}$：每个 KV head 的 hidden/head dimension；
- $S$：输入序列长度，本系统取 8192 或 16384；
- $B_{element}$：每个 KV Cache 元素占用的字节数，例如 BF16/FP16 为 2 bytes。

模型参数和序列长度确定后，先计算并配置本轮测试的 $B_{request}$，供 Grafana 将传输速率换算为请求速率。

## 6. 速率计算

全局 connector 的实际传输 payload 总量为
$$
\Delta C(t;W)=
\sum_e\sum_r
\left[
C_{e,r}(t)-C_{e,r}(t-W)
\right].
$$
$$
B_{request}
=
\frac{\Delta C(t;W)}{W}
=
\frac{
\displaystyle
\sum_e\sum_r
\left[
C_{e,r}(t)-C_{e,r}(t-W)
\right]
}{W}.
$$

设相邻两个实际采样时刻为 $t_1$、$t_2$，间隔都是 W，对应累计值为 $C(t_1)$、$C(t_2)$：

$$
rate(C)=\frac{C(t_2)-C(t_1)}{t_2-t_1}
$$

三类 req/s 分别为：

$$
R_{prefill}=\frac{P(t_2)-P(t_1)}{t_2-t_1}
$$

$$
R_{decode}=\frac{D(t_2)-D(t_1)}{t_2-t_1}
$$

$$
R_{kv}=\frac{K(t_2)-K(t_1)}{(t_2-t_1)\times B_{request}}
$$

其中 $P$、$D$ 是从各自 scheduler `running` 采集得到的当前请求数，$K$ 是 `FlagCXKVConnectorStats` 汇总得到的全局累计传输 bytes。


## 7. Grafana 展示

Grafana 使用同一时间轴展示三组数据：

| 数据       | 原始序列                              | 时间导数/换算结果          |
| -------- | --------------------------------- | ------------------ |
| Prefill  | Prefill scheduler `running` 当前请求数 | Prefill req/s      |
| Decode   | Decode scheduler `running` 当前请求数  | Decode req/s       |
| KV Cache | 所有 engine、所有传输线程的累计 bytes         | bytes/s 和 KV req/s |

Dashboard 默认每 1 秒刷新，Prometheus 默认每 1 秒 scrape。三条 req/s 曲线使用相同的时间范围和速率窗口，以便直接比较 Prefill、KV Cache 传输和 Decode 三个阶段的处理能力。
