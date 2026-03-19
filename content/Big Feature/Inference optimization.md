

## baai KT2 project
### 1. flagcx/flagGems support vllm pd disaggregation
 
 **核心工作 1：deepseek v3.2 使用 flag 系列完成vllm PD 分离推理**
 - [x] 由于 nixl 可以跑通，给出 nixl 支持双边 flagcx 设计文档 ，设计文档见：[[nixl  support flagcx backend]] ✅ 2026-03-13
 - [x] 讨论后，核心问题是 nccl 也是双边，但是deepseek v3.2为什么跑不通 vllm pd 分离，找到根本原因并修复 bug[[1. Bugfix for vllm deepseek v3.2 1p1d]] ✅ 2026-03-16
 - [x] 修复方案提交 vllm 社区 pr https://github.com/vllm-project/vllm/pull/37265 ✅ 2026-03-17
 - [ ] 给出当前修改/测试方案（支持 flagcx/falgGems/vllm-plugin-fl 跑通 vllm deepseek v3.2 pd 分离）[[2. vllm use vllm-plugin-fl、flagGemms and flagcx run Deepseek v3.2]]

**核心工作 2：glm-5 使用 flag 系列完成 vllm pd 分离推理**
 