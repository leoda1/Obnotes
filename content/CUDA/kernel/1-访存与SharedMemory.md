> 管什么：数据在显存各层怎么走、怎么访问才快，以及 shared memory 的 bank conflict 怎么避。

## 存储层级

## Global 访存

### 合并访问

### 向量化访存

## Shared Memory

### bank 与 bank conflict
- smem 分 32 个 bank，每个 4B，地址按 128B 一圈轮流映射到 bank 上。
- 同一个 warp 里多个线程访问同一个 bank 的不同地址，就要排队串行，这就是 bank conflict。
- 典型场景：tile 每行 128B，按列读（`ldmatrix`、转置）时 8 行的同一个 16B 块全落在同一组 bank，8 路冲突，要串行 8 次。

### padding 与 swizzle
**padding**：每行多留 16B，行跨度变 144B，各行错开 bank。代价是浪费空间，行跨度不再是 2 的幂，向量访问和 TMA 都不好配。

**swizzle**：写 smem 时按 XOR 规则打乱存放位置，不多占空间。128B swizzle 是把一行看成 8 个 16B 小块，块号和行号低 3 位做 XOR：

```
chunk' = chunk ^ (row % 8)
addr   = row*128 + chunk'*16      // smem 起点要 1024B 对齐
```

类比：8 辆车都想停 1 号车位只能排队；按"尾号 XOR 车位号"重新分配，一人一个位，一次停完。

| 模式 | XOR 位数 | 周期 | 用在 |
|---|---|---|---|
| 32B | 1 | 2 行 | 每行 32B |
| 64B | 2 | 4 行 | 每行 64B |
| 128B | 3 | 8 行 | 每行 ≥128B，最常用 |

平台差异：
- sm90：TMA 搬数据时硬件顺手 swizzle，读端（`ldmatrix`/wgmma）配同一种模式。
- sm80 / 810E：没有 TMA，用 `cp.async` 写 smem 时自己对地址做 XOR，CUTLASS 的 sm80 kernel 就这么干。
- 通信 kernel 基本是连续 1D 访问，一般用不上，主要是 GEMM / attention 的事。
