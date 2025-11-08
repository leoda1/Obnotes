# 0. 试验性的GPU侧API [[Device API]]
* 引入设备端 API，可将 NCCL 通信直接集成到应用的 kernel 中。
* 支持用于 CUDA P2P 的 LSA（Load/Store Access），覆盖 NVLink 以及部分 PCIe 平台。
* 支持 Multimem，利用 NVLink SHARP 实现硬件多播。
* 增加 GIN（GPU-Initiated Networking，GPU 发起网络通信） 的初始框架，当前仍在开发中。
* 引入通过 ncclDevCommCreate 创建的设备端通信器（device communicators）。
* 启用带同步（ncclLsaBarrierSession）与内存访问器（ncclGetLsaPointer, ncclGetLsaMultimemPointer）的设备端通信操作。
# [[diff from 1 to 7]]
# 1. 对称内存Symmetric memory
* ncclGroupStart/End的API支持对称操作。
* 使用设备端 API 重写对称内核。
# 2. host侧新的cc通信API
新增ncclAlltoAll、ncclScatter、ncclGather
# 3. CE（Copy Engine）集体通信
alltoall、scatter、gather、allgather 降低 SM 占用，需要在 ncclAllGather、ncclAlltoAll、ncclGather、ncclScatter 上启用该能力：将缓冲区注册到对称窗口，并在通信器 config_t 中使用 NCCL_CTA_POLICY_ZERO 标志。
# 4. NCCL监控插件
* 引入 Inspector 插件，用于常开式性能监控。
* 以结构化 JSON 形式输出每次 NCCL 操作的元数据、执行时间、带宽，以及可选的事件追踪。
* 可与 Performance Exporter 等分析工具集成，用于可视化 NCCL 性能瓶颈。
* 通过环境变量 NCCL_PROFILER_PLUGIN 与 NCCL_INSPECTOR_ENABLE 轻量启用。
# 5. Plugins
网络（Network）
* 面向应用的网络插件：NCCL 将通信操作信息传递给网络端点，便于更好地调优网络端点及其在插件中的使用。
* 改进对物理/虚拟网络设备的处理与加载/卸载。
* 网络插件版本 11：为每个通信器的初始化/结束增加显式上下文与通信 ID 支持。
* 新增多请求网络 API。使用该接口可让 NCCL 预判多路收发请求并进行优化。参见 ncclNetProperties_v11_t 中的 maxMultiRequestSize 字段。

分析器（Profiler）
* 增加对 API 事件（group、collective、p2p）的支持，并可追踪 kernel 启动到分析器插件里。
* 新增 Inspector Profiler 插件（见上节）。
* 添加对 Google 的 CoMMA 分析器（GitHub）的钩子。

调优器（Tuner）
* 通过 ncclTunerConstants_v5_t 在调优器初始化时暴露 NCCL 调优常量。
* 新增 NVL 域信息 API。
* 单一共享对象支持多种插件类型。

# 6. 新的参数化与 ncclConfig 变更
* 新增选项 NCCL_MNNVL_CLIQUE_ID=-2：将使用机架序列号来划分 MNNVL 团簇，从而把 NVLink 域限制在单个机架内的 GPU。
* 新增 NCCL_NETDEVS_POLICY：用于控制网络设备如何分配给 GPU。默认值（AUTO）保持与先前版本一致的策略。
* 新增 NCCL_SINGLE_PROC_MEM_REG_ENABLE：在“单进程多 rank”场景下，作为可选项启用 NVLS UB 注册。
* 将 nChannelsPerNetPeer 移入 ncclConfig。环境变量 NCCL_NCHANNELS_PER_NET_PEER 可覆盖 ncclConfig 中的该值。
* 默认启用 PxN over C2C
	* 在 Grace-Blackwell 平台上，通过允许 NCCL 利用经 NVLINK、C2C 与 PCIe 连接到对端 GPU 的 NIC，从而提升性能。
	* 如需关闭，可设置 NCCL_PXN_C2C=0。
# 7. 其他改进
* 允许在 pre-sm90 设备上对非约简（non-reductive）操作使用 FP8。（参见 https://github.com/pytorch/pytorch/pull/151594#discussion_r2135777776）
* 修复 NVLS+CollNet，并临时禁用在 >8 张 GPU 情况下的 COLLNET_CHAIN。
* 仅考虑运行中的网络接口用于 socket 流量。NCCL 将不再尝试使用未设置 IFF_RUNNING 位的接口。（https://github.com/NVIDIA/nccl/issues/1798）
* 现代化互斥量管理：转换为 std::mutex 和 std::lock_guard。
* 移除已长期弃用、且会导致最新 NCCL 版本构建问题的 sm35 与 sm50 目标架构（GENCODE）。
* 改进 NVLS/NVLSTree 的调优预测，以提升算法与协议选择的准确性。
* NVLSTree 调优修复：更新 H100、GB200-NV72 的调优数据。
* 对 RoCE 链路抖动响应更好：由原先报告“unknown event”改为报告“GID table changed”。
* 将 libvirt 桥接接口移动到候选接口列表的末尾，以便最后才被考虑。此类接口通常是主机上为容器转发流量的虚拟桥，不适用于到远端节点的通信，因此应避免用于实际流量。