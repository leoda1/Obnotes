

## baai KT2 project
### 1. flagcx/flagGems support vllm pd disaggregation
 
 **核心工作 1：deepseek v3.2 使用 flag 系列完成vllm PD 分离推理**
 - [x] 由于 nixl 可以跑通，给出 nixl 支持双边 flagcx 设计文档 ，设计文档见：[[nixl  support flagcx backend]] ✅ 2026-03-13
 - [x] 讨论后，核心问题是 nccl 也是双边，但是deepseek v3.2为什么跑不通 vllm pd 分离，找到根本原因并修复 bug[[1. Bugfix for vllm deepseek v3.2 1p1d]] ✅ 2026-03-16
 - [x] 修复方案提交 vllm 社区 pr https://github.com/vllm-project/vllm/pull/37265 ✅ 2026-03-17
 - [x] 给出当前修改/测试方案（支持 flagcx/falgGems/vllm-plugin-fl 跑通 vllm deepseek v3.2 pd 分离）[[2. vllm use vllm-plugin-fl、flagGemms and flagcx run Deepseek v3.2]] ✅ 2026-03-25
 - [x] 1P1D更改为 qwen 的 moe 模型跑出 mooncake/nixl/nccl 的 baseline 基础上，看 flagos 的性能 [[4. vllm mooncake&&nixl connector test]] ✅ 2026-03-30
 - [x] nsys去 profiler mooncake/nixl 32K 输入的 case [[4. vllm mooncake&&nixl connector test#6. profiler | profiler 1P1D]] ✅ 2026-03-31
 - [ ] 学习 mooncake 源码和 vllm 的不同 connector 的 kv cache 调度逻辑，拆分 flagcx connector 开发方案
     - [x] nixl 源码整体实现[[0. nixl research]] ✅ 2026-04-01
     - [ ] [doing]Mooncake connector实现 [[1. vllm 如何使用 mooncake 传输 kv cache]]
     - [ ] [doing]Mooncake xfer engine源码学习 [[0. mooncake rdma transfer]]
     - [ ] [doing]Nccl_connector->flagcx_connector 优化，放在vllm-plugin-fl；Nccl engine->flagcx engine，和mooncake性能对齐；
     - [ ] vllm 如何管理 kv cache，nixl 和 mooncake 的 connector 如何使用 block 索引 kv cache 并指挥底层 rdma
     - [ ] 统计单次 mooncake 传输的时间
 - [ ] glm 模型用 flagos 跑通 [[3. vllm glm5 1P1D 推理]]

**核心工作 2：glm-5 使用 flag 系列完成 vllm pd 分离推理**
 