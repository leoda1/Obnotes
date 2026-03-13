## 0. 前言

* NIXL的本身结构、分层以及运行流程； [[0. nixl research]]
* Flagcx 能参考的uccl plugin 都是怎么干的？[[1. what does UCCL do within Nixl]]
## 1. 具体方案
### nixl侧
nixl 内需要提供什么？ [[2. nixl flagcx backend design]]，nixl 侧需要实现：
1. flagcxEngine : public nixlBackendEngine
2. flagcxBackendMD : public nixlBackendMD
3. flagcxReqH: public nixlBackendReqH
4. flagcx_plugin.cpp
### flagcx侧
flagcx 封装一层 engine.cc\engine.h，来让 nixl 只依赖一个很小的头文件也不是跟 flagcx 内部的 comm.h,adaptor.h都混在一起。
但是改动这边比较大[[3. One side flagcx nixl engine design]]：（待定）

讨论后，确定第一版先考虑 NIXL 内支持双边的 Flagcx backend。[[4. Two-side flagcx nixl engine design]]
* https://jwolpxeehx.feishu.cn/file/B74lbmjHHoPHesx1znuc0iOanGe

## Phase 0/1 区别

| 维度             | Phase 0（双边 postXfer）       | Phase 1（单边 + 控制面）                   |
| -------------- | -------------------------- | ----------------------------------- |
| FlagCX 侧需实现的代码 | connect/send/recv/poll     | 完整控制面 + progress thread + 状态机       |
| 控制通道           | 不需要                        | 必须实现                                |
| 线程             | 无额外线程                      | progress thread + 可能的 accept thread |
| NIXL 侧改动       | 上层协调两端各自 postXfer          | 不改                                  |
| 通知支持           | 初期 `supportsNotif()=false` | 需控制通道                               |
| 匹配正确性          | 依赖 FIFO 顺序（flagcx 语义保证）    | 由 req_id + mem_token 显式匹配           |
