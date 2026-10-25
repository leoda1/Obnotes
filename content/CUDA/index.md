

# CUDA

| 目录            | 管什么                                             |
| ------------- | ----------------------------------------------- |
| kernel        | 写 kernel 过程中积累的                                 |
| PMPP          | 《Programming Massively Parallel Processors》读书笔记 |
| GPU-MODE      | GPU MODE 课程笔记（正文在 Notion）                       |
| Documentation | CUDA 官方文档：基础问题 + Driver/Runtime API 模块笔记        |

## kernel

按写 kernel 的知识链路排：先懂硬件 → 数据怎么搬 → 怎么算 → 怎么同步 → 怎么写底层指令 → 通信 → 调优 → 国产卡差异。

### 0-硬件与执行模型.md
执行模型：（暂无）

架构代际：
1. 各代关键能力：sm80/90/100 和国产卡的异步拷贝、Tensor Core、cluster、multimem、bf16 原子对照表。[[kernel/0-硬件与执行模型#各代关键能力]]
2. 810E 相当于哪一代：sm80 档（编译目标 ppu_10），没有 TMA / wgmma / cluster。[[kernel/0-硬件与执行模型#国产卡对标]]

### 1-访存与SharedMemory.md
存储层级 / Global 访存：（暂无）

Shared Memory：
1. bank conflict 怎么来的：32 个 bank 一圈 128B，按列读 128B 宽的 tile 会 8 路冲突。[[kernel/1-访存与SharedMemory#bank 与 bank conflict]]
2. swizzle 是什么：写 smem 时按 `chunk ^ (row%8)` 打乱位置，消除冲突且不浪费空间，比 padding 好。[[kernel/1-访存与SharedMemory#padding 与 swizzle]]

### 2-异步拷贝与TMA.md
cp.async：
1. sm80 的异步拷贝：每线程搬 4/8/16B，commit/wait 同步，810E 上能用的就是它。[[kernel/2-异步拷贝与TMA#cp.async]]

TMA：
1. 810E 支持 TMA 吗：大概率不支持，TMA 是 sm90 才有。[[kernel/2-异步拷贝与TMA#TMA]]
2. bulk.tensor 是什么：描述符 + 坐标一条指令搬一个多维 tile，硬件管 stride / 越界 / swizzle。[[kernel/2-异步拷贝与TMA#张量拷贝 cp.async.bulk.tensor]]

mbarrier：
1. TMA 搬完怎么通知：mbarrier 按字节计数，到齐才放行。[[kernel/2-异步拷贝与TMA#字节计数与完成通知]]

### 3-TensorCore与MMA.md
（暂无）

### 4-同步原子与内存模型.md
线程同步：（暂无）

原子操作：
1. 有没有 store 时顺便 add 的指令：用 `red`，L2 原子单元执行、不返回旧值，比 `atom` 便宜。[[kernel/4-同步原子与内存模型#atom 与 red]]
2. red 支持哪些类型：sm80 支持 u32/u64/f32/f16x2，bf16 和向量版要 sm90。[[kernel/4-同步原子与内存模型#各类型支持]]

内存模型：
1. relaxed / release / acquire 区别：relaxed 只保原子不保顺序，发信号用 release、读端用 acquire。[[kernel/4-同步原子与内存模型#语义 sem]]

### 5-PTX与内联汇编.md
PTX 基础：（暂无）

内联汇编：
1. 为什么要加 asm volatile：volatile 防删防合并，"memory" 防普通读写被重排，都只管编译器，硬件顺序靠 .release / fence。[[kernel/5-PTX与内联汇编#volatile 与 memory clobber]]

### 6-通信Kernel.md
通信协议：
1. KV迁移的batch是什么粒度：MHA slice按层分别提交K/V，列表项为单token的head切片，relay slot另行打包。[[kernel/6-通信Kernel#KV 缓存分片与批量传输]]
2. LayerSplit怎样改变PD发送：由全层部分token改成owner层的全部待迁移tokens，相同decode布局下总payload不自动减少；还需映射层地址并等齐owner，DSA latent不能按Q heads简单切份。[[kernel/6-通信Kernel#KV 缓存分片与批量传输]]
3. LayerSplit与PP怎样区分：只切缓存归属，CP各rank仍逐层计算本地query；主KV广播与每层indexer重叠，隐藏延迟不减少通信字节。[[kernel/6-通信Kernel#KV 缓存分片与批量传输]]
4. indexer是否生成主KV：输出的是top-k位置，索引key缓存与MLA主latent缓存独立；PD需两类状态，MLA各decode TP rank通常复制共享latent。[[kernel/6-通信Kernel#KV 缓存分片与批量传输]]
5. CP只算部分token为何有完整缓存：每层all-gather后写入kv_buffer[layer_id-start_layer]，池按完整PP层范围逐层分配，CP不减少层数，因此形成全层副本。[[kernel/6-通信Kernel#KV 缓存分片与批量传输]]

集合通信 kernel 结构：
1. RS 后哪些计算可以按 token 分工：完整行 norm 和复制权重投影可本地执行，逐行操作可移到 AG 前；前提是参数与行内依赖齐备，不能跨过尚未完成的求和。[[kernel/6-通信Kernel#RS 与逐行算子融合]]
2. TP 的 AR 与层边界怎样对应：o_proj 后归约进入 MoE 前 norm，MoE 后归约进入下一层 norm；两处通信边界可以对应三个融合kernel。[[kernel/6-通信Kernel#RS 与逐行算子融合]]
3. 融合收益怎样估：减少重复计算、消除回拷与纯融合分别计账，再扣新增通信和布局成本；小算子原时长不能全部当净收益。[[kernel/6-通信Kernel#融合收益预算]]
4. 少 head 为什么补齐：是具体 kernel 的形状约定，不是模型必需；去掉外部 padding 不会自动缩小内部 MMA tile。[[kernel/6-通信Kernel#TP 层边界与 trace 对照]]

### 7-性能分析与调优.md
（暂无）

### 8-国产卡适配.md
PPU：
1. 810E 能力验证清单：哪些指令已确认、哪些只是推断。[[kernel/8-国产卡适配#能力验证清单]]

昇腾 / DCU / MUSA：（暂无）

## PMPP

### Chapter1-3 Basic.md
入门三章：引言、GPU 计算历史、CUDA 简介。
1. 第 3 章：数据并行、程序结构、矩阵乘例子、显存分配与拷贝、kernel 与线程组织。[[PMPP/Chapter1-3 Basic#chapter 3. CUDA简介]]

### Chapter 7 Floating Point Considerations.md
浮点：格式、可表示的数、特殊位模式与精度、舍入误差、算法上怎么减小误差（目前只有提纲）。[[PMPP/Chapter 7 Floating Point Considerations]]

## GPU-MODE

### lecture notes.md
只放了 Notion 链接，正文在 Notion。[[GPU-MODE/lecture notes]]

## Documentation

### 0 basic
1. 必要.md：为什么 `CUDA_DEVICE_MAX_CONNECTIONS=1` 时 MoE 的 a2a 和 attn/mlp 会串行（问题已记，答案待补）。[[Documentation/0 basic/1. 必要#A. 单多硬件队列下多stream的调用限制]]

### 6 Modules
1. 6.1 Device Management：CUDA IPC 三件套 `cudaIpcGet/Open/CloseMemHandle`，跨进程共享显存。[[Documentation/6 Modules/6.1 Device Management]]
2. 6.4 Stream Management：`cudaThreadExchangeStreamCaptureMode`，切换 stream capture 模式，避免捕获期间调不安全的 API。[[Documentation/6 Modules/6.4 Stream Management]]
3. 6.14 VMM：虚拟内存管理全流程，预留地址 → 创建物理内存 → 映射 → 设权限 → 释放，可选导出句柄跨进程共享。[[Documentation/6 Modules/6.14 Virtual Memory Management(VMM)]]
4. 6.16 Multicast：Hopper 的 NVLink SHARP 组播内存，建组播对象、加设备、绑内存，再用 VMM 映射成 VA。[[Documentation/6 Modules/6.16. Multicast Object Management(组播对象管理)]]
