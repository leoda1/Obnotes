> **目标**：在 FlagCX 内构建一套统一的、多后端多线程的 IBRC P2P 传输栈，兼容 nixl backend 的 batchGet 与 flagcx connector 的 batchPut 调用
>
> - Worker 逻辑放在 `flagcx/core/flagcx_p2p.cc`
> - Ibverbs 封装放在 `flagcx/adaptor/net/ibrc_p2p_adaptor.cc`

---

## 1. 背景

### 1.1 两类上层调用

```
┌────────────────────────────────────────────────────────────────────┐
│                     nixl backend (C++ plugin)                       │
│  postXfer(local_descs, remote_descs)                                │
│   └─ 已切好的 IOV 列表（每个 desc 由 connector 内                    │
│       block_offset = block_id * block_len_per_layer 计算得到）       │
│   └─ 每个 IOV 对应一次独立 RDMA READ                                 │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ flagcxP2pEngineReadVector(...)
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                   flagcx connector (Python wrapper)                 │
│  flagcxBatchPut(comm, peer, src_offs, dst_offs, sizes,              │
│                 src_mrs, dst_mrs, count)                            │
│   └─ 已通过 group_concurrent_contiguous() 把多个连续 block 拼接为      │
│       较大的 entry，每个 entry 仍可能 >> 64K                          │
│   └─ 每个 entry 需要进一步切成 64K slice 后再下发                      │
└───────────────────────────────────────────────────────────────────┘
```

### 1.2 各后端当前丢下来的数据

#### (a) nixl backend — 一个 desc 对应一个 IOV

`postXfer` 中每个 `local[i] / remote[i]` 已是上层切好的最小单位。`prepXfer` 阶段把远端描述符反序列化为 `FlagcxP2pRdmaDesc`：

```c
struct FlagcxP2pRdmaDesc {
  uint64_t addr;     // 远端 base VA + offset（已绝对化）
  uint32_t size;     // == local[i].len
  uint32_t rkey;
};
```

进入 `flagcxP2pEngineReadVector` 时持有：

| 字段           | 来源                              | 含义                |
| ------------ | ------------------------------- | ----------------- |
| `dstVec[i]`  | `local[i].addr`                 | 本地 VA（READ 目标）    |
| `sizeVec[i]` | `local[i].len == remote[i].len` | 长度（已 ≤ block 粒度）  |
| `mrIds[i]`   | `lmd->mr_id`                    | 本地 MR ID → lkey   |
| `descs[i]`   | `FlagcxP2pRdmaDesc`             | 远端 (addr, rkey)   |

**特征**：上层已切好，IOV size 通常等于 KV cache 单 block 字节数（数 KB ~ 数百 KB），**不需要再切**。

#### (b) flagcx connector — 已 group 后的 entry，仍需二次切

Python connector 调用 `group_concurrent_contiguous()` 合并连续 block，得到的每个 entry 可能数 MB。下发 `flagcxBatchPut(...)` 时携带：

```python
flagcxBatchPut(
    comm, peer_rank,
    src_offs,   # list[size_t] — 源 MR baseVa 偏移
    dst_offs,   # list[size_t] — 目标 MR baseVa 偏移
    sizes,      # list[size_t] — entry 长度（可能 >> 64K）
    src_mrs,    # list[int]    — 源 MR 索引
    dst_mrs,    # list[int]    — 目标 MR 索引
)
```

**特征**：每个 entry 长度任意，**需要按 `kBlockSize`（默认 64 KB）二次切**，与 Mooncake `submitTransferTask()` 同款切法（含末尾 `kFragmentSize` 合并）。

### 1.3 当前实现的问题

1. **单 worker 串行**：`flagcx_p2p.cc` 中只有一个 `gAsyncWorker`，所有 vector 任务排队，无法并行多 conn / 多 QP。
2. **无 slice 抽象**：connector 路径直接 `ibv_post_send`，缺乏统一的 wr_id ↔ 任务回查机制；nixl 路径则用 `void* request` + `test()` 轮询，与 worker pool 模型不兼容。
3. **MR 注册路径混乱**：nixl 走 `flagcxP2pEngineReg`，connector 走 `flagcxOneSideRegister`（依赖 hetero comm 做 N×N allGather），两条路无法共享一份 MR / endpoint 池。
4. **rkey 交换强耦合**：connector 的 rkey 表 `globalOneSideHandleTable` 由 `flagcxOneSideRegister` 内的集合通信填充，nixl 又用 desc 序列化字符串，两套机制让 connector + nixl 无法共存于同一 ibrc_p2p 通路。
5. **flagcx connector内想用多 woker 就需要多 comm。。。**

---

### 总体结构

![[方案设计-backup 2026-05-25 22.14.59.excalidraw.svg]]
%%[[方案设计-backup 2026-05-25 22.14.59.excalidraw.md|🖋 Edit in Excalidraw]]%%

## 2. 第一步：统一 Slice 数据结构

### 2.1 设计原则

1. `FlagcxSlice *` **直接作为 `wr_id`**（强转 `uint64_t`），CQ 完成时无需查表。
2. 每个 slice 自带 `std::atomic<status>`，独立追踪状态。
3. `slice->task` 反向回指，slice 完成时 `task->successSliceCount.fetch_add(1)` 聚合任务级状态。
4. 通过 **C++ templte policy** 同时支持 ==nixl 1个 desc 是 1个 slice ==（去开 ucx 的 4 个 thread 来拿到最后的收益）==flagcx connector 64K是一个 slice== 切片两种切法，slice 结构本身保持单一。
5. Slice 对象走 free-list pool（`FlagcxSlicePool`），避免热路径 malloc。

### 2.2 核心数据结构

放置位置：新增头文件 `Flagcx/flagcx/include/flagcx_p2p.h`。

```cpp
// ─── 公共：远端 MR 描述（与具体交换机制解耦） ────────────────────────────
struct FlagcxRemoteMemDesc {
  uint64_t baseVa;   // 远端 MR base VA
  uint32_t rkey;     // 远端 rkey
  uint32_t deviceId; // 远端 IB 设备 idx（用于多设备路由）
  size_t   size;     // 区域长度（用于校验）
};

// ─── 任务：聚合多个 slice 的完成状态 ─────────────────────────────────────
struct FlagcxTransferTask {
  std::atomic<uint64_t> sliceCount{0};         // 总 slice 数（buildSlices 期间累加）
  std::atomic<uint64_t> successSliceCount{0};
  std::atomic<uint64_t> failedSliceCount{0};
  std::atomic<uint64_t> transferredBytes{0};
  std::atomic<bool>     finished{false};
  std::vector<FlagcxSlice*> sliceList;          // 仅 builder/poller 访问
};

// ─── Slice 状态 ────────────────────────────────────────────────────────
enum class FlagcxSliceStatus : uint8_t {
  PENDING  = 0, // 已 build，未入 queue
  QUEUED   = 1, // 已入 sliceQueue，等待 worker
  INFLIGHT = 2, // 已 ibv_post_send
  SUCCESS  = 3,
  FAILED   = 4,
};

// ─── Slice 主体 ────────────────────────────────────────────────────────
struct FlagcxSlice {
  // RDMA WR 必备 5 元组
  uint64_t srcVa;     // WRITE: local src; READ: local dst
  uint64_t dstVa;     // WRITE: remote dst; READ: remote src
  uint32_t length;    // ≤ kBlockSize（policy 决定）
  uint32_t lkey;
  uint32_t rkey;
  uint8_t  opcode;    // IBV_WR_RDMA_READ / IBV_WR_RDMA_WRITE

  // 路由信息（buildSlices 阶段填好）
  int                ibDevN;       // 选定的本地 IB 设备 → 选 WorkerPool
  std::string        peerNicPath;  // "host/mlx5_0" 风格 → 选 endpoint

  // 完成追踪
  std::atomic<FlagcxSliceStatus> status{FlagcxSliceStatus::PENDING};
  FlagcxTransferTask *task;        // 反指 task

  // QP 深度（Mooncake 同款，poll 后回扣）
  volatile int *qpDepth;

  // 重试
  uint8_t  retryCnt;
  uint8_t  maxRetryCnt;

  // Pool 标记
  bool     fromCache;

  inline void markSuccess() {
    status.store(FlagcxSliceStatus::SUCCESS, std::memory_order_release);
    task->successSliceCount.fetch_add(1, std::memory_order_relaxed);
    task->transferredBytes.fetch_add(length, std::memory_order_relaxed);
  }
  inline void markFailed() {
    status.store(FlagcxSliceStatus::FAILED, std::memory_order_release);
    task->failedSliceCount.fetch_add(1, std::memory_order_relaxed);
  }
};
```

### 2.3 Template Policy：兼容两种切法

放置位置：`Flagcx/flagcx/include/flagcx_p2p.h`。

```cpp
// ─── Policy A：nixl 路径，1 desc = 1 slice，不再二次切 ─────────────────
struct NixlSlicePolicy {
  static constexpr bool   kFurtherCut    = false;
  static constexpr size_t kBlockSize     = SIZE_MAX;
  static constexpr size_t kFragmentSize  = 0;
};

// ─── Policy B：connector 路径，按 64K 切，末尾合并 ─────────────────────
struct FlagcxSlicePolicy {
  static constexpr bool   kFurtherCut    = true;
  static constexpr size_t kBlockSize     = 64 * 1024;   // 可由 env 调整
  static constexpr size_t kFragmentSize  = 4 * 1024;    // 末尾合并阈值
};

// ─── 通用 builder ─────────────────────────────────────────────────────
template <typename Policy>
inline void buildSlices(
    FlagcxTransferTask        *task,
    FlagcxSlicePool           &pool,
    uint64_t                   srcVa,        // 已绝对化的本地 VA
    uint64_t                   dstVa,        // 已绝对化的远端 VA
    size_t                     totalLen,
    uint32_t                   lkey,
    uint32_t                   rkey,
    uint8_t                    opcode,
    int                        ibDevN,
    const std::string         &peerNicPath,
    uint8_t                    maxRetryCnt) {

  if constexpr (!Policy::kFurtherCut) {
    // —— nixl 分支：直接 1:1 ———————————————————————
    FlagcxSlice *s = pool.allocate();
    s->srcVa       = srcVa;
    s->dstVa       = dstVa;
    s->length      = static_cast<uint32_t>(totalLen);
    s->lkey        = lkey;
    s->rkey        = rkey;
    s->opcode      = opcode;
    s->ibDevN      = ibDevN;
    s->peerNicPath = peerNicPath;
    s->task        = task;
    s->retryCnt    = 0;
    s->maxRetryCnt = maxRetryCnt;
    task->sliceList.push_back(s);
    task->sliceCount.fetch_add(1, std::memory_order_relaxed);
    return;
  }

  // —— flagcx connector 分支：64K 切 + 末尾合并（与 Mooncake 完全一致）—————
  size_t off = 0;
  while (off < totalLen) {
    bool merge = (totalLen - off) <= Policy::kBlockSize + Policy::kFragmentSize;
    size_t len = merge ? (totalLen - off) : Policy::kBlockSize;

    FlagcxSlice *s = pool.allocate();
    s->srcVa       = srcVa + off;
    s->dstVa       = dstVa + off;
    s->length      = static_cast<uint32_t>(len);
    s->lkey        = lkey;
    s->rkey        = rkey;
    s->opcode      = opcode;
    s->ibDevN      = ibDevN;
    s->peerNicPath = peerNicPath;
    s->task        = task;
    s->retryCnt    = 0;
    s->maxRetryCnt = maxRetryCnt;
    task->sliceList.push_back(s);
    task->sliceCount.fetch_add(1, std::memory_order_relaxed);

    off += len;
    if (merge) break;
  }
}
```

### 2.4 两类调用方如何 build

#### nixl 路径（READ / batchGet）

```cpp
// 在 flagcxP2pEngineReadVector 内部（重构后）
auto *task = new FlagcxTransferTask;
for (int i = 0; i < numIovs; ++i) {
  // 1. 解析本地 MR
  auto &le = localEntries[i];
  uint32_t lkey = ((FlagcxP2pMrHandleView*)le.mhandle)->lkey;

  // 2. 用 NixlSlicePolicy（1:1）
  buildSlices<NixlSlicePolicy>(
      task, gSlicePool,
      /*srcVa=*/ descs[i].addr,                 // 远端 src（READ 时是远端 baseVa+off）
      /*dstVa=*/ (uint64_t)dstVec[i],           // 本地 dst
      /*totalLen=*/ sizeVec[i],
      lkey, descs[i].rkey,
      IBV_WR_RDMA_READ,
      le.ibDevN, conn->peerNicPath,
      /*maxRetry=*/ 7);
}
workerPool[le.ibDevN].submitPostSend(task->sliceList);
```

#### flagcx connector 路径（WRITE / batchPut）

```cpp
// 在新的 flagcxP2pEngineBatchPut（C++ 入口）中
auto *task = new FlagcxTransferTask;
for (size_t i = 0; i < count; ++i) {
  auto &srcMr = mrTable[srcMrs[i]];   // 本地 MR：(baseVa, lkey, ibDevN)
  auto &dstMr = remoteDescs[dstMrs[i]]; // FlagcxRemoteMemDesc：(baseVa, rkey)

  buildSlices<ConnectorSlicePolicy>(
      task, gSlicePool,
      /*srcVa=*/ srcMr.baseVa + srcOffs[i],
      /*dstVa=*/ dstMr.baseVa + dstOffs[i],
      /*totalLen=*/ sizes[i],
      srcMr.lkey, dstMr.rkey,
      IBV_WR_RDMA_WRITE,
      srcMr.ibDevN, conn->peerNicPath,
      /*maxRetry=*/ 7);
}
workerPool[srcMr.ibDevN].submitPostSend(task->sliceList);
```

### 2.5 Slice Pool

```cpp
class FlagcxSlicePool {
 public:
  FlagcxSlice *allocate();          // 优先从 freeList，否则 new + 标记 fromCache=false
  void         deallocate(FlagcxSlice*);

 private:
  // 简单方案：互斥 + 链表；高并发可演进到 thread-local cache + 全局后备
  std::mutex                  lock_;
  std::vector<FlagcxSlice*>   freeList_;
  static constexpr int kInitialReserve = 4096;
};
```

引擎全局一个 `gSlicePool`（不必 per-pool，分配热点不在切片本身）。

---

## 3. 第二步：WorkerPool 设计

完全对齐 `Mooncake/mooncake-transfer-engine/src/transport/rdma_transport/worker_pool.cpp`。

### 3.1 整体结构

```
FlagcxP2pEngine
├─ adaptor (flagcxNetIbP2p)
├─ FlagcxWorkerPool[ibDev=0]      ← 每个 IB 设备一个 pool（同 Mooncake）
│   ├─ transferWorker[0]   ─┐
│   ├─ transferWorker[1]    │  performPostSend + performPollCq
│   │   ...                 │  （worker 数量来自 env：FLAGCX_P2P_WORKERS_PER_CTX，默认 2）
│   └─ monitorWorker          ← epoll on context.async_fd
├─ FlagcxWorkerPool[ibDev=1]
└─ ...
```

### 3.2 类骨架

```cpp
// flagcx/core/flagcx_p2p.cc 内（不暴露给外部）
class FlagcxWorkerPool {
 public:
  FlagcxWorkerPool(int ibDevN, int numaSocketId);
  ~FlagcxWorkerPool();

  // 唯一对外接口（被 buildSlices 后的 engine 调用）
  int submitPostSend(const std::vector<FlagcxSlice*> &slices);

 private:
  void transferWorker(int threadId);
  void monitorWorker();
  void performPostSend(int threadId);
  void performPollCq(int threadId);
  void redispatch(std::vector<FlagcxSlice*> &failed, int threadId);

  // ── Sharded Slice Queue（Mooncake 同款，shard=8） ────────────────────
  static constexpr int kShardCount = 8;
  using SliceListPerPath =
      std::unordered_map<std::string, std::vector<FlagcxSlice*>>;

  SliceListPerPath          sliceQueue_[kShardCount];
  std::atomic<int>          sliceQueueCount_[kShardCount];
  std::mutex                sliceQueueLock_[kShardCount];

  // Per-worker 本地队列（避免锁竞争）
  std::vector<SliceListPerPath> collectiveSliceQueue_;

  // ── 进度计数 ──────────────────────────────────────────────────────────
  std::atomic<uint64_t>     submittedSliceCount_{0};
  std::atomic<uint64_t>     processedSliceCount_{0};
  std::atomic<int>          redispatchCounter_{0};

  // ── 线程管理 ──────────────────────────────────────────────────────────
  int                       ibDevN_;
  int                       numaSocketId_;
  int                       transferWorkerCount_; // 默认 2
  std::atomic<bool>         workersRunning_{true};
  std::atomic<int>          suspendedFlag_{0};
  std::mutex                condMutex_;
  std::condition_variable   condVar_;
  std::vector<std::thread>  workerThreads_;

  // ── 健康统计 ──────────────────────────────────────────────────────────
  std::atomic<int64_t>      successNrPolls_{0};
  std::atomic<int64_t>      failedNrPolls_{0};
};
```

### 3.3 submitPostSend（生产侧）

```cpp
int FlagcxWorkerPool::submitPostSend(const std::vector<FlagcxSlice*> &slices) {
  // 1. 按 (peerNicPath, ibDevN) 分 shard，减少跨 worker 抢锁
  SliceListPerPath shardBuckets[kShardCount];
  for (auto *s : slices) {
    s->status.store(FlagcxSliceStatus::QUEUED, std::memory_order_relaxed);
    int shardId = (std::hash<std::string>{}(s->peerNicPath) + s->ibDevN) % kShardCount;
    shardBuckets[shardId][s->peerNicPath].push_back(s);
  }

  // 2. 把每个 shard 整体并入全局 sliceQueue_
  uint64_t totalSubmitted = 0;
  for (int shardId = 0; shardId < kShardCount; ++shardId) {
    if (shardBuckets[shardId].empty()) continue;
    std::lock_guard<std::mutex> lock(sliceQueueLock_[shardId]);
    size_t cnt = 0;
    for (auto &[path, vec] : shardBuckets[shardId]) {
      auto &q = sliceQueue_[shardId][path];
      q.insert(q.end(), vec.begin(), vec.end());
      cnt += vec.size();
    }
    sliceQueueCount_[shardId].fetch_add((int)cnt, std::memory_order_relaxed);
    totalSubmitted += cnt;
  }

  submittedSliceCount_.fetch_add(totalSubmitted, std::memory_order_relaxed);

  // 3. 唤醒（如有 worker 在 cond_var 上挂起）
  if (suspendedFlag_.load(std::memory_order_relaxed)) {
    std::lock_guard<std::mutex> lk(condMutex_);
    condVar_.notify_all();
  }
  return 0;
}
```

### 3.4 transferWorker 主循环（消费侧）

```cpp
void FlagcxWorkerPool::transferWorker(int threadId) {
  bindToNumaSocket(numaSocketId_);

  constexpr uint64_t kIdleSpinNs = 100'000'000ULL;  // 100 ms
  uint64_t lastIdleTs = nowNs();

  while (workersRunning_.load(std::memory_order_relaxed)) {
    auto processed = processedSliceCount_.load(std::memory_order_relaxed);
    auto submitted = submittedSliceCount_.load(std::memory_order_relaxed);

    if (processed == submitted) {
      uint64_t now = nowNs();
      if (now - lastIdleTs > kIdleSpinNs) {
        std::unique_lock<std::mutex> lk(condMutex_);
        suspendedFlag_.fetch_add(1);
        if (processedSliceCount_.load() == submittedSliceCount_.load()) {
          condVar_.wait_for(lk, std::chrono::seconds(1));
        }
        suspendedFlag_.fetch_sub(1);
        lastIdleTs = now;
      }
      continue;
    }

    performPostSend(threadId);
    performPollCq(threadId);
  }
}
```

### 3.5 performPostSend

```cpp
void FlagcxWorkerPool::performPostSend(int threadId) {
  auto &localQueue = collectiveSliceQueue_[threadId];

  // 1. 从分配给本线程的 shards 拉取 slices
  for (int shardId = threadId; shardId < kShardCount; shardId += transferWorkerCount_) {
    if (sliceQueueCount_[shardId].load(std::memory_order_relaxed) == 0) continue;
    std::lock_guard<std::mutex> lk(sliceQueueLock_[shardId]);
    for (auto &[path, vec] : sliceQueue_[shardId]) {
      auto &dst = localQueue[path];
      dst.insert(dst.end(), vec.begin(), vec.end());
      vec.clear();
    }
    sliceQueueCount_[shardId].store(0, std::memory_order_relaxed);
  }

  // 2. 处理 redispatch（CQ 失败的 slice 重新走一遍）
  thread_local int tlRedispatchSeen = 0;
  if (tlRedispatchSeen < redispatchCounter_.load(std::memory_order_relaxed)) {
    tlRedispatchSeen = redispatchCounter_.load(std::memory_order_relaxed);
    auto clone = localQueue;
    localQueue.clear();
    for (auto &[_, vec] : clone) redispatch(vec, threadId);
    return;
  }

  // 3. 按 peerNicPath 分组下发 → ibrc_p2p_adaptor.cc::flagcxP2pIputBatch / IgetBatch
  std::vector<FlagcxSlice*> failed;
  for (auto &[peerNicPath, slices] : localQueue) {
    if (slices.empty()) continue;

    auto *ep = adaptorEndpoint(ibDevN_, peerNicPath);
    if (!ep || !ep->active()) {
      failed.insert(failed.end(), slices.begin(), slices.end());
      slices.clear();
      continue;
    }
    if (!ep->connected() && ep->setupActive() != 0) {
      failed.insert(failed.end(), slices.begin(), slices.end());
      slices.clear();
      continue;
    }

    // ─── 关键：按 opcode 选择 adaptor 函数 ──────────────────────────
    // READ 走老接口（nixl 兼容、签名不变）
    // WRITE 走新接口
    SplitByOpcode split(slices);
    if (!split.reads.empty()) {
      flagcxP2pIgetBatchSlices(ep, split.reads, failed);   // 内部 wr_id=slice
    }
    if (!split.writes.empty()) {
      flagcxP2pIputBatch(ep, split.writes, failed);         // 新增
    }
    slices.clear();
  }

  if (!failed.empty()) {
    for (auto *s : failed) s->retryCnt++;
    redispatch(failed, threadId);
  }
}
```

> 说明：`flagcxP2pIgetBatchSlices` 是对现有 `flagcxP2pIgetBatch` 的薄封装（保留旧 vtable 函数不变，新增内部 helper 接收 slice 列表并填 `wr.wr_id = (uintptr_t)slice`）。

### 3.6 performPollCq（与 Mooncake 完全一致的语义）

```cpp
void FlagcxWorkerPool::performPollCq(int threadId) {
  constexpr int kPollBatch = 64;
  std::unordered_map<volatile int*, int> qpDepthDelta;
  int processed = 0;

  for (int cqIdx = threadId; cqIdx < adaptorCqCount(ibDevN_);
       cqIdx += transferWorkerCount_) {
    ibv_wc wc[kPollBatch];
    int n = adaptorPoll(ibDevN_, cqIdx, wc, kPollBatch);
    if (n < 0) continue;

    for (int i = 0; i < n; ++i) {
      auto *s = reinterpret_cast<FlagcxSlice*>(wc[i].wr_id);
      if (s->qpDepth) qpDepthDelta[s->qpDepth]++;

      if (wc[i].status != IBV_WC_SUCCESS) {
        failedNrPolls_++;
        adaptorDeleteEndpoint(s->peerNicPath);  // 让连接重建
        s->retryCnt++;
        if (s->retryCnt >= s->maxRetryCnt) {
          s->markFailed();
          processed++;
        } else {
          collectiveSliceQueue_[threadId][s->peerNicPath].push_back(s);
          redispatchCounter_.fetch_add(1, std::memory_order_relaxed);
        }
      } else {
        s->markSuccess();
        successNrPolls_++;
        processed++;
      }
    }
    if (n > 0) adaptorCqOutstandingSub(ibDevN_, cqIdx, n);
  }

  for (auto &[d, c] : qpDepthDelta) __sync_fetch_and_sub(d, c);
  if (processed) processedSliceCount_.fetch_add(processed, std::memory_order_relaxed);
}
```

### 3.7 monitorWorker

```cpp
void FlagcxWorkerPool::monitorWorker() {
  bindToNumaSocket(numaSocketId_);
  // epoll on context.async_fd → 处理 IBV_EVENT_QP_FATAL / DEVICE_FATAL / PORT_*
  // 同 Mooncake：QP_FATAL 标记 endpoint inactive；DEVICE_FATAL 整个 context inactive
  ...
}
```

### 3.8 ibrc_p2p_adaptor.cc 改动

#### (a) `flagcxP2pIgetBatch` —— **完全保持不变**

> 用户要求：原本的 nixl 调用的 `flagcxP2pIgetBatch` 不变。所以现有 vtable `flagcxNetIbP2p.igetBatch = flagcxP2pIgetBatch;` 不动；nixl 当前路径（`asyncReadBatched` → `adaptor->igetBatch`）也保留作为兼容路径。

但为了让 worker pool 也能用 READ，新增一个内部 helper（不在 vtable 里）：

```c
// 仅供 worker pool 调用，签名以 slice 为单位
flagcxResult_t flagcxP2pIgetBatchSlices(
    struct flagcxP2pEndpoint  *ep,
    const std::vector<FlagcxSlice*> &slices,
    std::vector<FlagcxSlice*>       &failed);
```

实现内部仍调用同一份 ibv_post_send 逻辑，唯一差异是 `wr.wr_id = (uintptr_t)slice` 而非 request 索引。这样老接口零修改，新路径独立演进。

#### (b) 新增 `flagcxP2pIputBatch`

```c
// ibrc_p2p_adaptor.cc 内静态函数（注册到 adaptor->iputBatch；之前是 nullptr）
static flagcxResult_t flagcxP2pIputBatch(
    void                            *sendComm,   // FlagcxP2pCommView*
    int                              count,
    FlagcxSlice                    **slices);    // 已 build 好的 WRITE slice 列表

// 也提供 vector 版本以匹配 worker pool 调用风格（同 Mooncake submitPostSend）
flagcxResult_t flagcxP2pIputBatch(
    struct flagcxP2pEndpoint           *ep,
    const std::vector<FlagcxSlice*>    &slices,
    std::vector<FlagcxSlice*>          &failed);
```

实现要点：

1. 按 QP 数（`FLAGCX_P2P_QPS_PER_CONN = 4`）round-robin 分配 slice 到 QP。
2. 每个 QP 一次 `ibv_post_send` 链表式提交（最多 `FLAGCX_P2P_IGET_BATCH_MAX_WR = 64` 个 WR）。
3. WR 字段：
   ```c
   wr.wr_id              = (uintptr_t)slice;
   wr.opcode             = IBV_WR_RDMA_WRITE;
   wr.send_flags         = IBV_SEND_SIGNALED;     // 全部 signaled，便于 CQ 计数
   wr.sg_list[0].addr    = slice->srcVa;
   wr.sg_list[0].length  = slice->length;
   wr.sg_list[0].lkey    = slice->lkey;
   wr.wr.rdma.remote_addr= slice->dstVa;
   wr.wr.rdma.rkey       = slice->rkey;
   ```
4. 失败的 slice 直接放入 `failed`，由 worker pool 决定 retry / 终结。
5. 注册到 vtable：`flagcxNetIbP2p.iputBatch = flagcxP2pIputBatch;`（原先是 `nullptr`）。

---

## 4. 第三步：flagcx connector 改造

### 4.1 核心矛盾：rkey 交换与传输的解耦

> mooncake 是 `MooncakeAgentMetadata`...，这个交换需要和具体的传输接口解耦，不然 flagcx connector 可能没法和 nixl backend 一起使用我们的 ibrc_p2p

设计上必须做到：**`ibrc_p2p_adaptor` 与 worker pool 只认 `FlagcxRemoteMemDesc { baseVa, rkey }`**，至于这个结构是怎么来的（nixl 的 desc hex string、还是 Mooncake 的 RPC metadata），**完全交给上层 plugin/connector 自己的事**。

```
┌──────────────────────────┐         ┌──────────────────────────┐
│  nixl rkey 交换           │         │  Mooncake-style rkey 交换 │
│  (nixlBlobDesc.metaInfo  │         │  (HTTP/gRPC/torch.dist    │
│   = hex(FlagcxP2pRdmaDesc)│         │   传 baseVa + rkey 列表)   │
└────────────┬─────────────┘         └────────────┬─────────────┘
             │                                    │
             ▼                                    ▼
   ┌─────────────────────────────────────────────────────┐
   │       FlagcxRemoteMemDesc { baseVa, rkey, ... }      │  ← 解耦点
   └─────────────────────────────────────────────────────┘
                          │
                          ▼
   ┌─────────────────────────────────────────────────────┐
   │   buildSlices<Policy>  →  WorkerPool::submitPostSend │
   │   →  flagcxP2pIgetBatchSlices / flagcxP2pIputBatch    │
   └─────────────────────────────────────────────────────┘
```

### 4.2 引擎层新增的对外接口

放置位置：`flagcx/core/include/flagcx_p2p.h` 增量。

```cpp
// ─── 注册：返回本地 (baseVa, lkey, rkey)，供上层自由交换 ────────────────
struct FlagcxLocalMemDesc {
  FlagcxP2pMr mrId;
  uint64_t    baseVa;
  uint32_t    lkey;
  uint32_t    rkey;
  int         ibDevN;
};

int flagcxP2pEngineRegV2(FlagcxP2pEngine *engine,
                         void *buffer, size_t size,
                         FlagcxLocalMemDesc *out);

// ─── 反向注入远端 desc（与具体交换协议无关）────────────────────────────
//   nixl 路径：在 loadRemoteMD 里调用
//   connector 路径：Python 收到 metadata 后调用
int flagcxP2pEngineLoadRemoteMem(FlagcxP2pConn *conn,
                                 uint64_t remoteBaseVa,
                                 uint32_t remoteRkey,
                                 size_t   remoteSize,
                                 uint64_t *outRemoteMrHandle);

// ─── 新的 batchPut / batchGet（slice + worker pool 路径）──────────────
int flagcxP2pIputBatchEngine(FlagcxP2pConn *conn,
                             const uint64_t *srcOffs,
                             const uint64_t *dstOffs,
                             const size_t   *sizes,
                             const uint64_t *srcMrHandles,   // local
                             const uint64_t *dstMrHandles,   // 来自 LoadRemoteMem
                             size_t          count,
                             uint64_t       *outTaskId);

int flagcxP2pIgetBatchEngine(FlagcxP2pConn *conn, ...);   // 对称

// ─── 任务级查询/等待 ──────────────────────────────────────────────────
int flagcxP2pTaskQuery(uint64_t taskId, FlagcxTaskStatus *out);
int flagcxP2pTaskWait (uint64_t taskId);
```

> 注意：`flagcxP2pEngineLoadRemoteMem` 返回的 `remoteMrHandle` 只是引擎内部为远端 desc 分配的句柄；调用者不需要关心其内部表示。

### 4.3 nixl backend 的最小改动

nixl plugin 不需要换交换协议，只把现有的 `flagcxP2pEngineUpdateDesc` 路径换成「先 LoadRemoteMem 拿到 handle，再调用 batchGet」：

```cpp
// loadRemoteMD 内：从 input.metaInfo 反序列化得到 (baseVa, rkey)
flagcxP2pEngineLoadRemoteMem(conn, baseVa, rkey, len, &output_md->remoteHandle);

// postXfer 内 NIXL_READ：
flagcxP2pIgetBatchEngine(
    conn, srcOffs, dstOffs, sizes,
    localMrHandles, remoteMrHandles, count, &transferId);
```

老的 `flagcxP2pEngineReadVector` 可以作为 thin wrapper 保留一段时间，内部直接转发给 `flagcxP2pIgetBatchEngine`。

### 4.4 flagcx connector 的改造（Python 侧）

#### (a) 抛弃 `flagcxOneSideRegister` + `flagcxBatchPut` 老路径

老路径强依赖 hetero comm 做集合通信交换 rkey，不允许 connector 与 nixl 共存。新路径完全脱离 comm。

#### (b) 新 Python wrapper（`plugin/interservice/flagcx_wrapper.py`）

保留旧 4 个函数（`flagcxOneSideRegister / flagcxOneSideSignalRegister / flagcxBatchPut / flagcxPutSignal`）兼容旧 caller，**新增** 一组对应 P2P engine 的：

```python
# ── 引擎生命周期 ───────────────────────────────────────────
Function("flagcxP2pEngineCreate",  ctypes.c_void_p, []),
Function("flagcxP2pEngineDestroy", flagcxResult_t, [ctypes.c_void_p]),

# ── 注册 / 远端注入 ────────────────────────────────────────
Function("flagcxP2pEngineRegV2", flagcxResult_t, [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
    ctypes.POINTER(FlagcxLocalMemDesc),
]),
Function("flagcxP2pEngineLoadRemoteMem", flagcxResult_t, [
    ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_uint64),
]),

# ── 连接 ──────────────────────────────────────────────────
Function("flagcxP2pEngineGetMetadata", flagcxResult_t, [
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p),
]),
Function("flagcxP2pEngineConnect", ctypes.c_void_p, [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_bool,
]),

# ── 新 batchPut（走 worker pool）──────────────────────────
Function("flagcxP2pIputBatchEngine", flagcxResult_t, [
    ctypes.c_void_p,                     # conn
    ctypes.POINTER(ctypes.c_uint64),     # src_offs
    ctypes.POINTER(ctypes.c_uint64),     # dst_offs
    ctypes.POINTER(ctypes.c_size_t),     # sizes
    ctypes.POINTER(ctypes.c_uint64),     # local mr handles
    ctypes.POINTER(ctypes.c_uint64),     # remote mr handles
    ctypes.c_size_t,                     # count
    ctypes.POINTER(ctypes.c_uint64),     # out task_id
]),

Function("flagcxP2pTaskWait",  flagcxResult_t, [ctypes.c_uint64]),
```

#### (c) connector 内部使用范式（pseudocode）

```python
class FlagcxP2pConnector:
    def __init__(self, ...):
        self.engine = self.flagcx.flagcxP2pEngineCreate()
        self.local_meta = self.flagcx.flagcxP2pEngineGetMetadata(self.engine)
        # 把 local_meta 通过 vLLM 的 nixl_connector 兼容协议或自定义 rendezvous 发出去

    def register_kv(self, base_addr, size):
        local_desc = FlagcxLocalMemDesc()
        self.flagcx.flagcxP2pEngineRegV2(self.engine, base_addr, size,
                                         ctypes.byref(local_desc))
        # 把 (local_desc.baseVa, local_desc.rkey, size) 序列化进 metadata
        # —— 这里的 metadata 形态完全由 connector 自己决定，
        #    可以是 Mooncake 风格的 MooncakeAgentMetadata，
        #    也可以是 nixl 风格的 nixlBlobDesc.metaInfo
        return local_desc

    def on_remote_metadata(self, remote_meta):
        # 来自 PD 分离时 prefill / decode 的对端
        for layer in remote_meta.layers:
            handle = ctypes.c_uint64()
            self.flagcx.flagcxP2pEngineLoadRemoteMem(
                self.conn, layer.base_va, layer.rkey, layer.size,
                ctypes.byref(handle))
            self.remote_handles[layer.id] = handle.value

    def batch_put(self, src_offs, dst_offs, sizes, src_handles, dst_handles):
        task_id = ctypes.c_uint64()
        self.flagcx.flagcxP2pIputBatchEngine(
            self.conn,
            (ctypes.c_uint64 * len(sizes))(*src_offs),
            (ctypes.c_uint64 * len(sizes))(*dst_offs),
            (ctypes.c_size_t * len(sizes))(*sizes),
            (ctypes.c_uint64 * len(sizes))(*src_handles),
            (ctypes.c_uint64 * len(sizes))(*dst_handles),
            len(sizes), ctypes.byref(task_id))
        return task_id.value

    def wait(self, task_id):
        self.flagcx.flagcxP2pTaskWait(task_id)
```

### 4.5 Mooncake 风格 metadata 兼容样例

connector 完全可以模仿 Mooncake：

```python
@dataclass
class FlagcxAgentMetadata:
    remote_hostname: str
    remote_port:     int                 # = engine 的 IBRC listen port
    request_ids:     list[int]
    kv_caches_base_addr: list[int]       # 每层 tensor.data_ptr()
    kv_caches_rkey:      list[int]       # 来自 flagcxP2pEngineRegV2
    kv_caches_size:      list[int]
    block_ids:           list[int]
```

Decode 端收到后调用 `flagcxP2pEngineLoadRemoteMem` 把每层的 `(base_addr, rkey, size)` 转成内部 handle，再用 `flagcxP2pIputBatchEngine` 下发。

> nixl backend 的 plugin 并不感知这个 metadata —— 它仍然按 `nixlBlobDesc.metaInfo` 那套 hex 字符串来。两条交换路径产物都是 `FlagcxRemoteMemDesc`，自然在 `ibrc_p2p_adaptor` 这一层汇合。

---

## 5. 待办

1. **NUMA bind 策略**：FlagCX 现在没有显式的 NUMA-IB 拓扑映射，`bindToNumaSocket` 的实现需要复用 `p2p_topo.cc` 的设备 BDF → NUMA 节点信息。
2. **Endpoint 生命周期**：Mooncake 用 `endpoint_store` + LRU；FlagCX 当前每个 conn 持 4 QP，可以先简化为「peerNicPath ↔ FlagcxP2pConn」直接映射，后续再演进。
3. **连续两次任务的并行度**：worker 数量先固定为 2，但需要测过 200Gbps 单 NIC 是否足够；预留 env `FLAGCX_P2P_WORKERS_PER_CTX` 调参。
4. **READ 路径迁移时机**：本次设计已让 worker pool 同时支持 READ/WRITE，但 nixl 老路径（`flagcxP2pEngineReadVector` → 单 `gAsyncWorker`）保留，等 connector 上线稳定后再统一切到 worker pool。
5. **slice retry 与连接漂移**：当 `peerNicPath` 对应的 endpoint 被 deleteEndpoint 清掉后，redispatch 阶段需要按 `targetSegment` 重新 `selectDevice`，逻辑可暂时简化为「同一 peerNicPath 重试」，复杂版后续按 Mooncake `redispatch` 完整复刻。
