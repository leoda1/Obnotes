# PTD dashboard 里的 6 个队列指标

都是瞬时 gauge(当前队列里有几个请求),不是速率。面板:`sglang-ptd.json` 的 "P/D Pipeline Occupancy and Queue Depth"。

一个请求的流转:

```
Prefill: bootstrap_queue → waiting_queue → 跑 prefill → inflight_queue → 完成
Decode : prealloc_queue  → transfer_queue → waiting_queue → running_batch
```

## Prefill 侧

- **bootstrap_queue**:请求刚到 prefill,在等 decode 那边"我准备好了,KV 往这儿发"。decode 没准备好就一直堵在这。
- **waiting_queue**:握手完了,排队等 prefill 算。堆得多 = prefill 算力不够。
- **inflight_queue**:prefill 算完了,KV 正在往 decode 传,传完才释放。这里停多久 = KV 传输耗时,传输引擎慢就会在这堆起来。

## Decode 侧

- **prealloc_queue**:请求刚到 decode,要先和 prefill 握手,再给它预留 KV 显存、槽位。显存或槽位不够就堵在这。
- **transfer_queue**:地址已经告诉 prefill 了,等 KV 数据到齐。和 prefill 的 inflight 是同一段传输的两端。
- **waiting_queue**:KV 到齐了,等着进 running batch。堆得多 = decode batch 满了。

`num_queue_reqs` 在 prefill 和 decode 共用同一个指标名,靠 `engine_type` 标签区分,所以面板上 waiting_queue 有两条。

## 看图定位瓶颈

| 现象 | 瓶颈 |
|---|---|
| prefill waiting 高 | prefill 算力 |
| prefill bootstrap 高 + decode prealloc 高 | decode 显存/槽位不足 |
| prefill inflight 高 + decode transfer 高 | KV 传输(网络/传输引擎) |
| decode waiting 高 | decode batch 满 |

## 流程图

```

┌─────────── Prefill ───────────┐              ┌───────────── Decode ─────────────┐
│ bootstrap_queue               │◄──握手/地址── │ prealloc_queue                   │
│  (等 decode 握手)              │              │  (等握手 + 预留 KV 显存/槽位)    │
│        ▼                      │              │        ▼                         │
│ waiting_queue                 │              │ transfer_queue                   │
│  (等 prefill 调度)             │              │  (等 KV 数据到齐)                │
│        ▼                      │──── KV ─────►│        ▼                         │
│ inflight_queue                │    传输       │ waiting_queue                    │
│  (KV 传输中)                   │              │  (等进 running batch)            │
│        ▼                      │              │        ▼                         │
│      释放 KV                   │              │ running_batch → 逐 token decode  │
└───────────────────────────────┘              └──────────────────────────────────┘
```

## 源码位置(sglang/python/sglang/srt/)

- 指标取值:`managers/scheduler_components/metrics_reporter.py:779-815`
- prefill 队列:`disaggregation/prefill.py`(`pop_bootstrapped` 422,inflight 处理 943)
- decode 队列:`disaggregation/decode.py`(`pop_preallocated` 1086,`pop_transferred` 2294,`process_decode_queue` 2718)
