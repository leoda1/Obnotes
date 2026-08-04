## baai KT 1+2 project
### 1. flagcx/flagGems support vllm pd disaggregation
 
 **核心工作 1：deepseek v3.2 使用 flag 系列完成vllm PD 分离推理**
 - [x] 由于 nixl 可以跑通，给出 nixl 支持双边 flagcx 设计文档 ，设计文档见：[[nixl  support flagcx backend]] ✅ 2026-03-13
 - [x] 讨论后，核心问题是 nccl 也是双边，但是deepseek v3.2为什么跑不通 vllm pd 分离，找到根本原因并修复 bug[[1. Bugfix for vllm deepseek v3.2 1p1d]] ✅ 2026-03-16
 - [x] 修复方案提交 vllm 社区 pr https://github.com/vllm-project/vllm/pull/37265 ✅ 2026-03-17
 - [x] 给出当前修改/测试方案（支持 flagcx/falgGems/vllm-plugin-fl 跑通 vllm deepseek v3.2 pd 分离）[[2. vllm use vllm-plugin-fl、flagGemms and flagcx run Deepseek v3.2]] ✅ 2026-03-25
 - [x] 1P1D更改为 qwen 的 moe 模型跑出 mooncake/nixl/nccl 的 baseline 基础上，看 flagos 的性能 [[4. vllm mooncake&&nixl connector test]] ✅ 2026-03-30
 - [x] nsys去 profiler mooncake/nixl 32K 输入的 case [[4. vllm mooncake&&nixl connector test#6. profiler | profiler 1P1D]] ✅ 2026-03-31
 - [x] 学习 mooncake 源码和 vllm 的不同 connector 的 kv cache 调度逻辑，拆分 flagcx connector 开发方案 ✅ 2026-05-23
     - [x] nixl 源码整体实现[[0. nixl research]] ✅ 2026-04-01
     - [x] flagcx connector实现，放在vllm-plugin-fl；Nccl engine->flagcx engine，和mooncake性能对齐； [[5. flagcx connector design&&dev&&test]] ✅ 2026-05-7
     - [x] Mooncake xfer engine源码学习 [[0. mooncake rdma transfer]] ✅ 2026-05-23
     - [x] vllm 如何管理 kv cache，nixl 和 mooncake 的 connector 如何使用 block 索引 kv cache 并指挥底层 rdma ✅ 2026-05-23
 - [x] 在 flagcx 内设计、开发、测试一套多线程高性能的post wr+poll cq（定义general的数据结构处理上层的业务输入，然后flagcx_p2p内能初始化2worker）[[2. 多后端多线程的 ibrc p2p 方案设计]] ✅ 2026-06-02
 - [x] flagcx p2p engine 增加 rpc 服务以及对外的 python wrapper [[3. flagcx ibrc p2p RPC 服务 + flagcx connector 改动]] ✅ 2026-06-02
 - [x] [[4. vllm v1 调度逻辑 和 distributed 分布式原理]] ✅ 2026-06-10
 - [x] 不连续 kv transfer benchmark 设计开发测试 [[1. 不连续kv transfer benchmark 设计开发测试]] ✅ 2026-06-15
 - [x] 小 size 的 latency 优化 https://jwolpxeehx.feishu.cn/docx/DJandd7giocB4IxDQrrcEfWannc ✅ 2026-06-24
 - [x] 跑通 沐曦 平台 qwen / glm 以及 pd 分离 https://infrawaves.feishu.cn/wiki/SrA9wOxRHimlrIkZwxocRkBQnWd ✅ 2026-07-30
 - [x] 升级 flagcx connector 从 vllm0.13 到0.22 [[6. flagcx connector 升级至 vllm0.22]] ✅ 2026-07-14
 - [x] 0.24 vllm mooncake bashline + 0.24 vllm mooncake bashline + 0.20 vllm flagcx bashline ✅ 2026-07-14
 - [x] sglang 支持 flagcx connector https://infrawaves.feishu.cn/wiki/N8S3wbyQniBzQIks9bhcRB9KnE6 ✅ 2026-08-04
 - [x] ppu 后续独立优化可行性分析 ✅ 2026-08-04
 - [ ] glm 模型用 flagos 跑通 [[3. vllm glm5 1P1D 推理]]
 - [ ] 跑通 海光 平台 qwen / glm 以及 pd 分离 [[0. hygon && muxi]]

**核心工作 2：glm-5 使用 flag 系列完成 vllm pd 分离推理**
 