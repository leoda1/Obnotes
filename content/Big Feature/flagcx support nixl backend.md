## 0. 前言

* NIXL的本身结构、分层以及运行流程； [[0. nixl research]]
* Flagcx 能参考的uccl plugin 都是怎么干的？[[1. what does UCCL do within Nixl]]
* flagcx 内需要提供什么？ [[2. flagcx_engine design]]

## 1. 具体方案
nixl 侧需要实现：
1. flagcxEngine : public nixlBackendEngine
2. flagcxBackendMD : public nixlBackendMD
3. flagcxReqH: public nixlBackendReqH
4. flagcx_plugin.cpp

[[3. flagcx integrate into nixl design]]