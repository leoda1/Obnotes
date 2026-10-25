>目标 :  prefill --pp-size P（P>1）或者 cp>1，decode --pp-size 1。P个 preill pp rank 各自持有模型的 1 / p 层，各自独立地把自己那一段层的 KV 直接 RDMA 写进 同一个 decode rank 的显存。在推理场景除了支持mooncake已有场景 ，并从根源解决上述多打一场景，进一步提升性能。

# Timeline:
- [x] 确定dev 方向为 send-side pxn ✅ 2026-08-12
- [x] 输出具体的 send-side pxn 方案 ✅ 2026-08-14
- [ ] 开发出第一版代码，并跑通pp8,tp8的 pd 分离 [[1.1. dev record]]
    - [x] 开发 piece builder、rail map、Desc/Completed ABI、序列工具、环境变量、lane 和 slot 布局 ✅ 2026-08-14
    - [x] 机内 rank 之间的 cpu 共享内存注册，hbm 的 relay buffer alloc+register 以及完善的 RailResolver 初始化逻辑 ✅ 2026-08-20
    - [x] 每个 lane pipeline 流水调度，cudaMemcpyBatchAysnc+doorbell ✅ 2026-08-20
    - [x] 开发 build piece 完之后丢到对应机内其他 relay rank 并转发的调度 ✅ 2026-08-21
    - [x] 在 multi transport 增加 pxn transport 层的注册 使用 ✅ 2026-08-21
    - [x] piece 到 slice 的流程变近 ✅ 2026-08-21
    - [x] 修复不同 batch put 调用后导致的 relay 内的 counter 只增不减的 hang ✅ 2026-08-24
    - [x] mooncake 选网卡逻辑变更为就只用最近的一张 nic(不然会我们的机内选同轨 nic 会选错) ✅ 2026-08-24、
    - [x] 增加日志 判断 pxn 的数据流向 ✅ 2026-08-24
    - [x] 增加 tebench 的测试，和 sglang 端到端的测试，并输出文档 ✅ 2026-08-24
- [ ] 优化性能 [[1.3 pxn transfer engine test and optim]]
    - [x] 增加双口网卡支持，确定 pfc 得到有效解决，commit: 71b641d0de3c98f3616ce6e731d60915e4056a0d ✅ 2026-08-29
    - [x] sender 侧改为 2 个线程分别下 cudaMemcpyBatchAsync、submitToRdma，以及 poll 任务从一次 poll 一个改为 poll 一堆。性能确定达到 97%原生 ✅ 2026-08-29
    - [x] 在日志内增加 lane 内每个 slots 状态，确定当前瓶颈在下nvlink操作被 sglang 阻塞。具体原因为多个 batch 操作会被 reshard 到上层的一个线程内，导致并发的 batch—WriteSync 操作少，然后下nvlink操作的并行度大打折扣。 ✅ 2026-08-30
    - [ ] 
- [ ] 验证多类 pp、cp 场景下 engine 的最佳参数
    - [ ] cp 
- [ ] 收敛完整代码为一个独立传输引擎仓库 
    - [ ] 评估当前的hicache/mooncake store 等逻辑
- [ ] 发布第一版传输引擎

# 设计文档
[[1. kv cache transfer plan of pp and cp]]


# 开发文档
功能为独立的 pxn transport，早期借用 mooncake 的 topo，rpc，ib verbs 等资源，后续会独立出来。
https://github.com/leoda1/Mooncake/pull/2
[[1.1. dev record]]
[[1.2 code structure]]
 [[1.3 pxn transfer engine test and optim]]

# 测试文档
https://infrawaves.feishu.cn/wiki/OquOwZ0QjifAqEkDPDmcXrrPnph
