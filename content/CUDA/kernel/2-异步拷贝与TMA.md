> 管什么：让数据搬运和计算重叠的那套机制，从 sm80 的 cp.async 到 sm90 的 TMA，以及配套的 mbarrier。

## cp.async
sm80 引入，global → smem 异步拷贝，不经过寄存器。
- 每个线程自己搬 4/8/16B，地址自己算。
- 用 `cp.async.commit_group` 打包、`cp.async.wait_group` 等待。
- 810E 上能用的异步拷贝就是这个。

## TMA
sm90 起才有的专用搬运单元。一个线程发指令，TMA 自己算地址、自己搬，不占其他线程。

810E 大概率没有（sm80 档，未实测）。PCCL 里唯一的 `cp.async.bulk` 在第三方 DOCA 代码里，被 `DOCA_GPUNETIO_VERBS_HAS_TMA_COPY` 宏包着，默认不开。

### 1D 块拷贝 cp.async.bulk
搬一段连续字节，参数是地址和字节数。通信 kernel 多用这个。

### 张量拷贝 cp.async.bulk.tensor
TMA 的张量模式：host 上用描述符讲清楚多维张量长什么样，kernel 里给坐标，一条指令搬一个 tile。

| | `cp.async.bulk` | `cp.async.bulk.tensor` |
|---|---|---|
| 搬什么 | 一段连续字节 | 1D~5D 张量里的一个 tile |
| 怎么寻址 | 地址 + 字节数 | 描述符 + 坐标 |
| stride / 越界 | 自己算 | 硬件处理，越界填 0 |
| swizzle | 无 | 有（32/64/128B） |
| multicast | 无 | 一次读广播给 cluster 内多个 CTA |

流程：
1. host：`cuTensorMapEncodeTiled` 生成 128B 的 `CUtensorMap`（基地址、各维大小和 stride、类型、box 大小、swizzle）。
2. 以 `__grid_constant__` 参数传进 kernel。
3. 一个线程发指令，绑一个 mbarrier。
4. 搬完靠 mbarrier 的字节计数通知大家。

```cpp
asm volatile(
  "cp.async.bulk.tensor.2d.shared::cluster.global.mbarrier::complete_tx::bytes"
  " [%0], [%1, {%2, %3}], [%4];"
  :: "r"(smem_addr), "l"(&tmap), "r"(x), "r"(y), "r"(mbar_addr) : "memory");
```

主要用在 GEMM / attention（CUTLASS 3.x、FlashAttention-3）做 warp specialization：少数线程管搬运，其余 warp 专心算。

### 写回与规约
- smem → global：`cp.async.bulk.tensor.2d.global.shared::cta`。
- 写回顺便累加：`cp.reduce.async.bulk.tensor...add`，store 时 reduce 的 TMA 版。

## mbarrier

### 字节计数与完成通知
TMA 指令绑定一个 mbarrier，按到达的字节数计数，到齐了才放等待的线程过去。
