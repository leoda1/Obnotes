# PCP / DCP：计算、KV 布局与块轮转

> 基于 2026-09-10 本地 SGLang 代码。TP8 + DCP8 的收益以共享 latent KV 的 MLA 模型为例，其他 attention 结构不能直接套用相同收益。

## 1. Prefill 为什么可以并行，decode 为什么逐步生成

Prefill 开始时，整个 prompt 已知，所有 token 的 embedding 可以直接得到。Decode 的下一个输入 token 要从上一步 logits 中采样，因此普通自回归生成必须逐步进行。

一个 Transformer 层可简化为：

```text
层输入 → Q/K/V 投影 → Attention → 后续计算（含 MLP）→ 下一层
```

同层的 Q/K/V 由各 token 自己的层输入生成，可以同时计算：

```text
t0 → Q0、K0、V0      Q0 看 K0、V0
t1 → Q1、K1、V1      Q1 看 K0..K1、V0..V1
t2 → Q2、K2、V2      Q2 看 K0..K2、V0..V2
t3 → Q3、K3、V3      Q3 看 K0..K3、V0..V3
```

**t3 需要同层的 K2、V2，不需要等待 t2 完成同层 attention，更不需要等待 t2 跑完整个模型。** 下一层使用上一层输出，层间仍有依赖。

## 2. PCP 与 DCP 分担什么

CP（Context Parallel）沿上下文维度分担工作，解决长上下文的计算、KV 容量和读取带宽问题。

| | Prefill CP / PCP | Decode CP / DCP |
|---|---|---|
| 工作对象 | 多个已知 prompt token | 当前新 token 与历史 KV |
| 典型分工 | 不同 rank 处理不同 query 位置，通信获取所需 KV | 不同 rank 保存、扫描不同历史 KV 分片 |
| 均衡关注点 | query 位置决定可见历史长度 | 普通 dense decode 中主要看有效 KV 数量 |

PCP 的一种示意分工：rank0 处理 t0..t3，rank1 处理 t4..t7。每层先各自生成 Q/K/V，再通过 all-gather、ring 等方式获得需要的 K/V，各自完成 attention。

rank1 会等待当前层所需的远端 K/V，但不必等 rank0 跑完所有层才能开始工作。不同 PCP 实现的通信方式可以不同。

Prefill 中，靠后 query 看更多历史，连续均分 query 可能导致 causal attention 工作量不均。Token RR 或 block RR 能分散位置，但不保证计算量严格相等。

Decode 中，历史 KV 已经算好。读取 t100 的 KV 不需要重新计算 t0..t99；对同一个当前 query，普通 dense attention 中每项历史 KV 的成本大致相近。因此，按数量均分的连续 KV 分片也可以均衡。

## 3. Prefill 到 decode 的完整流程

```text
完整 prompt 已知
  → Prefill 逐层计算，保存各层 prompt KV
  → 最后一个 prompt 位置的最终 hidden state → logits → 第一个新 token
  → D 端准备好所需 KV 和第一个新 token
  → Decode 输入该新 token，逐层访问历史 KV，并加入自身 KV
  → logits → 下一个 token → 重复
```

第一个新 token 通常由 prefill 最后位置的输出采样；第一个常规 decode forward 输入它，预测第二个新 token。

Chunked prefill 只是分批处理 prompt。普通执行路径下，同一请求需要完成所有 prompt chunk，才能得到最终位置的 logits 并进入正常 decode。某个 token 的某一层 attention 完成，不足以生成第一个新 token。

P/D 分离时，KV 可以按层或 chunk 提前传输，与 prefill 重叠；“开始传 KV”和“请求可以开始 decode”是两个不同时间点。

## 4. TP8 + DCP8 如何工作，为什么有效

### 4.1 从切 heads 转为切历史 KV

当前 DCP group 建在 TP group 内。TP8 + DCP8 使用同一组 8 张 GPU，不是 64 张。投影等阶段仍采用相应的 TP 分工，decode attention 使用上下文分片。

设总 query head 数为 H，上下文长度为 N。以 MLA 的共享 latent KV 为例：

```text
TP8、DCP1：每卡 H/8 个 query heads × 全部 N 个历史 KV
TP8、DCP8：每卡 H   个 query heads × 本地约 N/8 个历史 KV
```

**Gather 的是各 rank 的 query head 分片，通常一次 all-gather 拼出 DCP 组内所需的 query heads；不是每次只 gather 一个 head，也不是 gather 全部历史 KV。**

每层的典型过程：

1. 各 TP rank 生成本地 query head 分片。
2. 沿 head 维度 all-gather Q。
3. 各 rank 用这些 Q 对自己的约 1/8 KV 做局部 attention。
4. 合并局部 softmax 归一化信息与输出，再把输出分回相应 TP head 分片。
5. 继续模型后续计算。

当前 Triton decode 路径明确使用 Q all-gather 和 `cp_lse_ag_out_rs_mha` 归并；其他 backend 的具体通信实现需分别核对。

局部输出不能直接取平均。对于同一个 query/head，若 rank r 的局部输出为 O_r，局部 log-sum-exp 为 L_r：

```text
L = logsumexp(L_0, ..., L_7)
O = Σ_r exp(L_r - L) × O_r
```

空分片需要提供零权重等价的归一化状态，不能让无效 KV 进入 softmax。

### 4.2 收益来自 KV 容量和读取，不是计算少了 8 倍
MLA 的多个 query heads 共享 latent KV。普通 TP 可以切 query heads，但共享历史 KV 往往在各 TP rank 复制。

假设一个请求所有层的 MLA KV 总计 8 GB：

| 配置 | 每卡 KV | 8 卡合计 KV |
|---|---:|---:|
| TP8、DCP1，KV 复制 | 约 8 GB | 约 64 GB |
| TP8、DCP8，KV 分片 | 约 1 GB | 约 8 GB |

这是 KV 的理想化示例，不包括权重、其他 buffer 和 padding。

主要收益：

- 减少重复 KV 存储，容纳更多请求或更长上下文。
- 减少每卡需要扫描的历史 KV 数据，改善长上下文 decode 的带宽瓶颈。
- 显存释放后可以增加 batch，提高吞吐。

代价是 Q 和局部结果的通信。历史 KV 随 N 增长，每步 Q/输出的通信量不随 N 同比例增长，因此长上下文更容易受益。

每卡主要 attention 运算量从 `(H/8) × N` 换成 `H × (N/8)`，没有减少 8 倍。实际读取量和速度取决于 kernel、batch、上下文长度及互联；短上下文可能被新增通信抵消收益。MHA/GQA 若 KV heads 已充分切分，也不能照搬 MLA 的收益预期。

## 5. 当前 token RR：逻辑跳着分，本地紧凑存

当前检查到的 DCP 路径按 token round-robin 分配：

```text
rank0：t0、t8、t16、t24……
rank1：t1、t9、t17、t25……
……
rank7：t7、t15、t23、t31……
```

按请求逻辑位置 t 表达：

```text
owner(t) = t % P
local_index(t) = t // P
```

local_index 是请求在本 rank 的逻辑序号，物理地址还要经过页表。实现中也存在对 allocator 虚拟 slot 取模、整除的路径，依赖相应对齐规则。

**逻辑 token 跳着分，不代表 D 端内存也留空洞。** rank0 可以紧凑存为 `[t0][t8][t16]...`，但不同物理 page 未必连续。

P 端若按原 token 顺序存储，发给 rank0 就要跨步抽取 t0、t8、t16……。目标地址可以连续，源地址却不连续。当前 Mooncake 路径只有源、目标同时连续时才合并传输段，因此容易产生小碎片。

### Per-token RR 的优缺点

优点：

- 单个请求在任意长度下，各 rank 的有效 KV 数量最多相差 1。
- 不需要知道最终长度；新增 token 交给下一个 rank，不搬旧 KV。
- D 端本地可以紧凑存放，dense decode 扫描工作量接近。

缺点：

- 从顺序存储的 P 端取数时源地址跨步，容易产生大量小传输段。
- 与整页传输粒度不一致，可能增加打包、索引或传输描述符开销。
- 均衡的是 KV 数量，不保证所有 kernel 时间、请求间负载或 prefill FLOPs 严格均衡。

## 6. Block RR：块内连续、块间轮转

设块大小 B、DCP 大小 P：

```text
owner(t) = (t // B) % P
local_index(t) = (t // (B × P)) × B + t % B
```

B=1 退化为 token RR。DCP4、B=4：

```text
t0..t3   → rank0
t4..t7   → rank1
t8..t11  → rank2
t12..t15 → rank3
t16..t19 → rank0
t20..t23 → rank1
```

前 16 个 token 分完后，各 rank 都有 4 个 KV。再新增 8 个，数量成为 `8、8、4、4`。新增 token 自然回到 rank0、rank1，不用搬旧 KV。

**每分完一整轮 P 个块，各 rank 一样多；任意中间时刻，单请求的各 rank KV 数量最多相差 B。** 当 N 远大于 P×B 时，差距占比较小。

长度 N 在 rank r 上的有效 KV 数量：

```text
local_len(N, r) = (N // (P×B)) × B
                + clamp(N % (P×B) - r×B, 0, B)
```

区间 [S, S+L) 的数量为 `local_len(S+L,r) - local_len(S,r)`。Chunk 必须使用请求全局位置，不能每个 chunk 从 rank0 重新开始轮转。

| | Token RR | Block RR |
|---|---|---|
| 单请求各 rank KV 数量差 | 最多 1 | 最多 B |
| 从顺序源 KV 取数 | 跨 token 抽取 | 块内连续取数 |
| 新增 KV | 每 token 换 rank | 填完块再换 rank |
| 搬旧 KV | 不需要 | 不需要 |
| 短请求 | 分配较均匀 | 可能仅少数 rank 有 KV |

B 可以取物理 page size 的整数倍，从 B=page_size 开始测试较合适。但跨物理 page 未必连续，不能保证整个 B 都是一笔传输。

每层通常有独立 buffer。Block RR 解决的是每层内部的 token 碎片，不会自动把所有 layer 的 KV 合成连续内存。

多请求都从 rank0 起步时，尾部偏斜可能累积。每请求轮换起始 rank 可以缓解，但会增加布局元数据和缓存复用约束。

### 为什么不一直连续均分

已知长度时，连续均分历史 KV 也能让 dense decode 均衡。问题是后续增长：如果要求每个 rank 始终只有一段逻辑连续区间，新增 KV 接到最后一段会失衡，重新均分又需搬旧 KV。

新增 token 接回 rank0 完全可行；此时各 rank 拥有多个逻辑区间，已经是这里的 block RR。本地仍可紧凑存放这些区间。

## 7. P 端是否也要开启 CP

**计算分工、KV 存储归属、P→D 传输布局是三个问题。**

- P 端可以用适合 prefill 的计算分工，D 端用 block RR，中间处理映射或重排。
- P 端若原本连续存储，仅 D 端改 block RR，就能改善源端取数连续性，不要求 P 端按相同 block 计算。
- 两端 KV 分片布局完全一致时，对应 rank 之间可以更直接地传输，但不代表两端 attention 计算方式相同。

当前代码支持相同 DCP 布局的 P/D 对接，要求 DCP rank 匹配；也支持特定 MLA 路径从 P 的 DCP1 转成 D 的 DCP>1。当前尚未实现这里讨论的可配置 block RR。

按当前配置方式，两端使用相同 DCP 分片意味着两边配置 DCP；不能因此推断 P 端采用了相同的 PCP query 分工。代码还提示：P 端开启 DCP 可能增加通信，而不改善 prefill 性能。

## 8. Padding 与动态 CP

Padding 可以统一容量或 kernel shape，不能消除有效工作量差异。无效位置必须被 mask 排除，不能改变真实 token 位置或采样语义；如果 kernel 仍扫描 padding，就是增加空工作。

短请求采用较小 CP 有机会减少通信和空 rank，但需要调度、执行与 collective 支持。请求开始时选定 CP 大小并固定，比生成中途改变 CP 简单。中途切换会改变 KV owner，通常需要迁移或重组已有 KV。

动态 CP 与 block RR 互补，不是实现 block RR 的前提。

## 9. SGLang 改造范围

这是 KV 布局改造，不是简单把循环步长从 1 改成 B。限定单 backend、单 PD 路径属于中等规模；全面覆盖现有 DCP 路径，范围会明显扩大。

| 模块 | 需要修改或核对 |
|---|---|
| 公共 DCP layout | owner、本地索引、有效长度、带起点区间计数 |
| KV 写入 | 新 token 归属、本地物理地址 |
| Attention 元数据 | 页表、索引、最大长度、空分片、CUDA Graph 元数据 |
| P→D 传输 | 按块选源 KV、目标映射、块大小协商、chunk/prefix 偏移 |
| Allocator 与缓存 | 页对齐、容量、释放、prefix 复用及其他缓存路径 |
| Extend / verify | 多 query causal mask、位置映射、边界处理 |

当前 allocator 使用 `physical_page_size × DCP_size` 的虚拟页规则。B=physical_page_size 时，一轮每个 rank 获得一页，较容易对应现有结构，但仍需修改映射。B=k×physical_page_size 时，需要额外核对多页块分配及尾部空间。

普通单 token decode 的局部 attention 和 softmax 归并原理不变，但 backend 内部的索引、位置与 causal 处理仍需核对。

第一版建议固定 DCP 大小，限定实际使用的一个 backend 和 Mooncake，支持 B=1 与 B=page_size；后续再扩展多页块、动态 CP。

验证重点：

- 输出正确性、跨块追加、尾块与空 rank。
- 分 chunk 传输、prefix 偏移、页分配释放、CUDA Graph。
- 适用的多 token verify/extend 路径。
- 传输段数量、KV 传输耗时、decode TPOT、吞吐和显存。

### 当前代码入口

- `python/sglang/srt/layers/dcp/layout.py`：公共长度与索引计算。
- `python/sglang/srt/layers/dcp/planner.py`：仍包含 token RR 筛选假设。
- `python/sglang/srt/layers/attention/triton_backend.py`：DCP KV 写入、Q gather、输出归并。
- `python/sglang/srt/layers/attention/cutedsl_mla_backend.py`：本地长度与页表。
- `python/sglang/srt/disaggregation/common/utils.py`：传输 token 映射。
- `python/sglang/srt/disaggregation/mooncake/conn.py`：连续传输段合并。
- `python/sglang/srt/disaggregation/common/conn.py`：P/D DCP 拓扑与重排判断。
- `python/sglang/srt/arg_groups/pd_disaggregation_hook.py`：PD DCP 支持边界与 P 端提示。
- `python/sglang/srt/mem_cache/pool_host/base.py`：host cache 的 DCP slot 映射假设。

## KV cache 管理：逻辑位置、物理 pool 与 PD 传输

### 逻辑 token 如何找到物理 KV

请求内的 token 位置不是物理内存地址。请求映射表记录逻辑 token 对应的 slot；allocator 按 page 分配物理空间，attention 再用索引或页表访问各层 KV。

以非 DCP 源端、page_size=64 为例：

```text
请求逻辑位置：  t0..t63       t64..t127      t128..t191
分配的 page：      5              9               2
物理 slot：   320..383       576..639        128..191

slot = page_id × 64 + offset_in_page
```

一个请求的 page 可以不连续，页内 slot 连续。下面按请求访问顺序画，不是按物理地址排序：

```text
每层物理 pool：
slot: 320 321 322 ... 383 | 576 577 ... 639 | 128 129 ... 191
      └── page 5 ───────┘ └── page 9 ────┘ └── page 2 ────┘
```

普通按 token 行存储的 K 或 V buffer 中，一行对应一个 token 的本地 KV-head 数据，字节数约为：

```text
local_kv_head_num × head_dim × dtype_bytes
```

K、V 分开存时，该式分别描述一个 K 或 V buffer；总 KV 大小需要两者相加。MLA 使用压缩 latent 等布局，不能直接套用普通多头 K/V 行大小；量化也可能附带 scale。传输应以实际 buffer 的 item length 为准。不同 backend 可能采用不同物理排列。

例如 allocator 本次取出的 page 顺序是 [5,9,2]，则展开为：

```text
[5,9,2] → [320..383, 576..639, 128..191]
```

当前 paged allocator 的基本 alloc 路径从 free_pages 前部取页。因此若 free_pages 实际顺序为 [2,5,9]，基本路径会按 [2,5,9] 分配，不能直接推导出 [5,9,2]。空闲页集合与实际分配顺序需要区分。

### 普通 PD：page 粒度的地址和长度

对完整页、无需 TP 切片或其他重排的传输，kv_indices 表示 page 号：

```text
源 kv_indices = [5,9,2]
page_item_len = 64 × token_item_len

源地址 = src_ptr + page_id × page_item_len
目标地址 = dst_ptr + dst_page_id × page_item_len
长度 = page_item_len
```

源、目标 page 号分别来自两端分配结果，不要求相等。

本例三个源 page 不相邻，在一个 layer 的一个 transfer buffer 内对应三个页大小的传输段，每段搬 64 行。若多页在源、目标两端都连续，可以合并。

这里的“3 个 RDMA block”指提交给传输层的三个地址段，不保证等于三个网络包或三次独立 API 调用。多层、K/V 多 buffer 的传输段还要分别计算，传输引擎可以批量提交。

### PD + DCP：从完整源页抽取本 rank 的 token

以下特指当前 P 的 DCP1 → D 的 DCP8 的 MLA 重排路径。两端相同 DCP 布局时，不一定需要这次 token 抽取。

设请求从位置 0 开始，无 prefix/chunk 偏移，DCP8 的 rank1 接收：

```text
请求位置 t：1, 9, 17, 25, 33, 41, 49, 57,
           65, 73, ... 121,
           129, 137, ... 185

源 page [5,9,2] 映射后的 slot：
321, 329, 337, 345, 353, 361, 369, 377,
577, 585, 593, 601, 609, 617, 625, 633,
129, 137, 145, 153, 161, 169, 177, 185
```

规则是按请求逻辑位置筛选 `t % 8 == 1`，再映射源物理 slot。不是一般性地按物理 slot 取模；本例 page_size=64 可被 8 整除、起点也对齐，二者才碰巧一致。有 prefix 和 chunk 时，使用请求全局位置。

“每个 token 轮转”表示 owner 每个 token 换一个 rank；某个 rank 在源序列中的采样步长是 N=8，不是 1。注意数列应为 321、329、337，335 不属于这组。

目标端把这些 token 紧凑写进自己的物理页。例如目标 page 为 10：

```text
源 slot：321 329 337 ... 377 | 577 ... 633 | 129 ... 185
目标 slot：640 641 642 ... 647 | 648 ... 655 | 656 ... 663

src_addr = src_ptr + src_slot × token_item_len
dst_addr = dst_ptr + dst_slot × token_item_len
length   = token_item_len
```

192 个源 token 中，rank1 获得 24 个。目标连续，但源不连续；在这个简单布局下，一个 layer 的一个 buffer 产生 24 个 token 大小的传输段。当前代码只有源、目标同时连续时才合并为更大的段。

DCP 的紧凑物理存储还配合 allocator 的虚拟 slot / 页映射：当前逻辑分配页大小采用 `physical_page_size × DCP_size`，不能把 D 端虚拟 slot 直接当成本地物理行地址。

### Block RR 改善哪一段

如果改为 B=64、DCP8，源请求的第 0 个逻辑块给 rank0，第 1 个给 rank1，第 2 个给 rank2：

```text
请求 block0 → 源 page5 → D rank0 的某个本地 page
请求 block1 → 源 page9 → D rank1 的某个本地 page
请求 block2 → 源 page2 → D rank2 的某个本地 page
```

归属按请求的逻辑块编号轮转，不按源物理 page_id 取模。发往各 rank 时可以搬完整连续页，避免从页内每隔 8 行抽一行。

代价是这个只有 3 个块的短请求暂时只占用 3 个 rank；长请求每完成 8 个块，各 rank 获得同样数量的 KV。它改善的是每层内的传输连续性，不会把不同层的 buffer 自动合并。
