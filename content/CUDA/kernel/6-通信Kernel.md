> 管什么：卡与卡之间怎么直接读写、通信协议怎么设计、集合通信 kernel 怎么写。

## P2P 与互联

## 通信协议

### KV 缓存分片与批量传输

KV 迁移要分开看 token、head、layer 三个维度。attention TP 按 head 分，CP 按 query token 分；CP 的计算分工不必等于持久缓存布局，也不必等于跨机发送分工。某些 CP 实现 allgather KV 后在每卡保存全序列，再人为分配发送页以分摊 NIC 压力。

SGLang本地DSA/MLA的forward_mla在每层调用rebuild_cp_kv_cache，对本地latent执行cp_all_gather_rerange_output，恢复全局token顺序后交给backend写入本rank缓存池；indexer也先汇集index key，再量化写入自己的索引缓存。无prefix、单4096-token chunk、CP4时，每rank只投影本地约1024个token，却能在该层汇集后保存4096个token的缓存；逐层执行并保留，最终每rank有全部层缓存。不是所有层结束后才统一汇集。存在prefix或多chunk时，汇集的是当前计算部分，历史缓存来自先前保留或加载。

持久化的源码证据需同时看分配和写入：model_runner_kv_cache_mixin以num_effective_layers创建NSA池，NSATokenToKVPool继承MLATokenToKVPool；后者kv_buffer为每层独立分配[size+page_size,1,kv_cache_dim]。backend将汇集后的KV按out_cache_loc写进kv_buffer[layer_id-start_layer]，下一层切换列表项而不复用上一层buffer。PP1时该层范围覆盖全模型，CP不把layer_num除以CP；size是整个池的token槽容量，不是某个请求的长度。这里只说明普通GPU缓存路径，HiSparse等分层存储需按其实现另看。

Transformer 是整体网络结构，attention 是每层子模块，sparse attention 只访问所选历史位置。MLA（Multi-head Latent Attention）用共享低维latent表示多头K/V，并保留位置相关分量；实现可用吸收权重的方式在压缩空间计算，不必完整展开所有head。MLA解决缓存表示大小，稀疏attention解决每个query访问哪些位置，两者可结合。

DSA indexer 用当前query的索引表示与历史index key缓存打分，输出top-k历史位置。indexer cache保存历史token的索引key及量化scale，主KV保存attention使用的latent与位置分量，两者来自各自投影，不是小缓存经indexer加工成主KV。PD需传历史主KV和indexer状态；新query会重新选位置，不能只传prefill最后一次top-k所指的KV。部分实现可复用相邻层top-k，但这不改变两类缓存的区别。

SGLang Mooncake 的 MHA/GQA 异构 TP slice 路径中，一次函数调用对应一个请求 chunk、一个源 rank、一个目标 rank。每层 K 和 V 各调用一次 batch；batch 内每项是一个 token 的目标 heads 连续字节，条目数为本 rank 页数乘 page_size。地址列表是 scatter/gather 描述，并未先把数据打包为一个连续 GPU buffer。同步只表示该 batch 等待完成，不表示不同层、不同进程串行。

以标准 Qwen3-30B-A3B 的48层、4个KV heads、head_dim128、BF16为例，prefill TP4/CP4 的 attention TP 为1，decode TP4 每卡持1个KV head。每项发送256B，每个源到目标每chunk调用96次batch；源token步长1024B，目标步长256B，因此源相邻token的所选head并不连续。

单请求4096-token chunk的Qwen CP计算将序列分为8个512-token段，rank r取第r和第7-r段以均衡因果attention负载；这叫zigzag。KV汇集保存后，传输代码另按连续页范围分为4份，每rank发送1024tokens。某层K到某个decode rank的一次batch有1024条256B描述，总payload256KiB；即使目标连续，也不能称为一次连续256KiB源拷贝。

relay slot 大小属于传输协议的打包容量，不等于模型 token、page 或 Python batch 大小。多个256B条目可以放入512KiB piece，但仍受相同目标、lane和描述符条目数等约束；不能仅凭slot大小推断一次RDMA请求或一次batch大小。

LayerSplit 将完整序列的不同层交给不同 CP owner 持久化。按此布局迁移时，每个owner负责自己层的待迁移全部tokens；若再按CP rank筛成四分之一tokens，就会漏发。owner广播供其他CP rank临时计算，不意味着其他rank长期拥有可供异步RDMA读取的稳定副本。

在相同待迁移token集合、精度和decode布局下，旧的全CP发送分工为每rank的全部层乘部分tokens，按层owner发送则为部分层乘全部待迁移tokens；均匀分层时每rank有效payload可保持相同，PD总payload也不因prefill缓存去重而自动减少。decode若保持原布局，不必引入LayerSplit；各owner可直接写入decode各全局层的目标页，无需先在prefill汇集。每层消息变大、层数减少是否改变batch次数，取决于原来逐层还是全层合批，不能推断RDMA WR必然减少。

owner发送需将本地层槽映射到decode全局层指针，主KV和indexer状态都按实际归属处理。decode在所有必需owner的数据完成后才能将整个请求标为就绪；临时广播buffer若用作发送源，必须保留到异步传输完成，不能计算结束就复用。

LayerSplit 的层归属是缓存存储分工，不是 PP 的层计算分工。CP rank 仍为自己负责的 query tokens 逐层执行 indexer 和 sparse attention；PP 则由不同 stage 执行不同层并传递 hidden states。indexer 属于每层 attention 的前置计算，不是在所有层结束后执行一次。

[Z.ai 原文](https://z.ai/blog/scaling-pain)图4(b)中，当前层 owner 先广播 indexer cache；各 rank 等其就绪后执行本地 indexer，同时另一 stream 广播该层主 KV；sparse attention 必须等待 indexer 结果和主 KV 均就绪。非 owner 只需当前计算所用的临时缓存，才能避免重新保存所有层的副本；具体缓冲区数量与回收策略未在文章中公开。

忽略资源争用和额外整理成本，设小缓存广播耗时为 B_i、主 KV 广播为 B_k、indexer 计算为 I，新增可见延迟约为 B_i + max(0, B_k - I)。文章称 indexer cache 约为主 KV 的1/8，指大小比例；只有主 KV 广播充分被 indexer 计算覆盖时，可见新增延迟才主要剩小缓存广播，实际通信字节仍包含主 KV。

DSA/MLA压缩KV与Q heads是不同布局。decode TP按Q heads分工时，各rank通常仍需要完整压缩latent和indexer缓存，不能把latent简单切成head数对应的四份。LayerSplit下的PD适配还须统一主KV、indexer+scale的层映射、源buffer存活时间及完成通知；文章只公开存储原理时，具体batch策略属于设计推断，未实测。

旧CP可只让CP0发送全层全token，也可让所有CP按token分摊；这是两种发送模式。LayerSplit owner直接发送时，每个owner向需要这些层的各decode rank发送owned_layers乘全部待迁移tokens。普通MHA/GQA按目标KV head切片，MLA的共享latent通常在各decode TP rank复制，后者不能写成每个decode head都单独发送一份。SGLang的attention TP大小为总TP除以attention DP再除以CP，只有相应比值为1时才是attention TP1。

## 多播与规约

## 集合通信 kernel 结构

### RS 与逐行算子融合

Row-parallel GEMM 按求和维 K 分工，每卡输出完整形状 `[T,H]` 的部分和。RS 沿 token 行分配归约结果，每个 owner 获得若干完整行；RMSNorm 沿 H 求平方均值，因此 owner 能独立完成 norm。residual 在归约后加一次。

`AR -> norm` 可以改成 `RS -> 本地行 norm -> AG`。按 token 分工减少跨卡重复计算，融合另外减少启动次数和中间写回、重读；两者的收益要分别计算。

对于逐 token 独立、参数一致的操作 f，若每行所需 residual、位置或其他状态都在所属 rank 齐备，沿 token 维有 `f(concat(X_r)) = concat(f(X_r))`。因此可把 `AG -> 全量 f` 改为 `本地 f -> AG`，再融合本地计算与发送。同形状同 dtype 时，AG 的通信量没有变化；减少的是各卡重复计算。这里只跨越拼接，不能据此把非线性 norm 移到跨卡求和之前。

一个 TP decoder 层常有 o_proj、MLP/MoE 输出两处 AR。两处都替换时，稳态对应两组 RS+AG；MoE 后的 RS 可以延后到下一层 input norm，配对的 AG 放在下一层复制权重投影之后。跨层移动不代表少了一组通信，逻辑通信阶段数也不等于融合后的 kernel launch 数。

两处通信边界不等于两个融合kernel：o_proj后可将RS+add+norm+AG放在一个kernel内；MoE后的RS+add+norm与投影后处理+AG被独立GEMM隔开，通常对应两个kernel。两处norm采用同一行分工时，residual可一直按行保存，只汇集下游需要的规范化结果；若其中一处仍要求完整residual，则需额外恢复该布局。

复制权重的投影可以在本地 token 上继续运行。按输出头切权重的投影仍要得到全部 token 输入，通常须在它前面 AG。RoPE 沿每个 token 的配对特征计算，移动到 AG 前时要携带原位置，不能使用分片后的局部行号。

保留现成 GEMM 时，可分为 `RS+add+norm`、独立 GEMM、`逐行后处理+AG`。前后两个融合 kernel 仍通过 GEMM 的显存输入输出衔接，不会消除这段 HBM 读写。

多分支网络必须枚举每个消费者：某分支需要原 hidden，即使主分支只需更窄的 latent，也不能直接丢弃 hidden。可以本地算完该分支后汇集产物，或者保留对应输入的通信。

数学等价不保证浮点逐位一致：归约顺序、BF16 舍入位置、norm 累加类型和量化 scale 都影响结果。带跨卡自旋的 kernel 还要保证被等待的 block 能执行；`__launch_bounds__` 不提供所有 block 同时驻留的保证。

### TP 层边界与 trace 对照

TP 按 head 分工时，每卡处理全体 query token 和一部分真实 heads；CP 按 query token 分工时，每卡处理一部分 token 和全体 heads。两者覆盖的是同一个 token×head 网格。P 张卡各取不同的 T/P 行、又只保留原来的 heads/P 列，仅覆盖 P 个对角块，会遗漏其余组合；同时分片需建立 TP×CP 二维分组，或通过通信改变 Q/输出的分布。query 分片不代表只需本地 KV，仍须访问这些 query 依赖的历史 KV。

有效工作量相同不代表实际 kernel 工作量相同。若 sparse attention 的最小 head 宽度是64，总64头在TP16下每卡只有4个真实头，却传入补齐的 `[T,64,D]`；CP16传入 `[T/16,64,D]`，形状规模相差16倍。若调用接口只传补齐张量、不传有效head数或mask，kernel不能按原始4头自动缩小任务；算完再截输出不会追回已消耗的时间。实际加速还受KV长度、访存和调度影响，不能直接按形状倍数承诺。

少 head 的 attention 在数学上无需补到64。适配层补齐通常为了满足某个 kernel 的形状约定，不能据此认定硬件只支持64头。去掉外部 padding 还需底层支持有效head数、尾部边界和调度；即使通过mask避免越界，内部固定MMA tile仍可能计算空行，速度不随有效head数等比例下降。

Pre-norm decoder 层按 `input norm -> Q/K 投影与 RoPE -> attention 核心 -> o_proj -> AR -> residual add + norm -> MLP/MoE -> AR` 执行。MLP 输出的 residual add 常与下一层 input norm 融合，因此 trace 中 norm 前的 AR 可能属于上一层 MoE。

首层先保存 embedding 为 residual，再单独 norm；词表分片 embedding 本身也可能需要 AR。后续层的 AR 归约子层输出的部分和，residual 已在旁路保存，由 add norm 把两者相加。通信结果的 DtoD 回拷不是首层特征。

attention 模块包含输入投影、RoPE、attention 核心和输出投影。单个 FlashAttention kernel 只对应核心计算；o_proj 属于 attention 的输出端，在 MoE 之前。MLA 还可能在核心前后各有独立的 latent 投影 GEMM。

Q-RoPE、K-RoPE 可以只是数据流名称。一个 RoPE kernel 可以同时旋转 Q 和 K；把 K 的计算移到 AG 前，意味着修改原联合调用的边界，不能在原 trace 中寻找一个独立 K-RoPE kernel。

MoE 的 `ep_scatter`、`ep_gather` 名称不代表一定跨卡：它们可以只是本地按专家排列 token，以及按路由权重合并专家输出。路由专家结果与共享专家相加，也不是层间 residual add；后者常在输出归约后的 add norm 中执行。

### 融合收益预算

总收益先算减少重复计算和消除回拷的时间，再扣新通信、数据布局和分片边界转换增加的时间。纯融合收益需比较相同分片、相同传输协议下的分离与融合版本，不能重复加上已经计入的 norm、quant 缩时。

`activation + quant` 或 `ep_gather + scale + shared add` 融合仍须完成原数学运算，可省的是启动和中间读写；原有小算子时长之和不是净收益。大 GEMM、attention 核心不变时，整层加速比例由这部分未优化时间限制。
