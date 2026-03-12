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
flagcx 侧薄封装一层 flagcx_nixl_engine.cc\flagcx_nixl_engine.h，来让 nixl 只依赖一个很小的头文件也不是跟 flagcx 内部的 comm.h,adaptor.h都混在一起。

但是改动这边比较大[[3. flagcx nixl engine design]]：
* flagcx_nixl_engine.h/.cc
* flagcx_nixl_control_plane，如果是双边的话就得连接握手、接收 READ/WRITE 请求、完成通知、错误回传
* flagcx_nixl_conn，如果是双边就得用这个保存每个 peer 的连接、能力、transport 类型、通知通道、请求状态
* flagcx_nixl_mr / remote_md，用来区分本地注册后的状态/远端的导入后的 meta_data
* flagcx_nixl_req / progress，post/check xfer 的异步推进/轮询
* one-sided handle export/import，NIXL_READ走单边，得重构flagcxOneSideRegister来适配 nixl 的 pairwise 模型
* NIXL_READ 的 native-get，看后续 flagcx 情况。
* https://jwolpxeehx.feishu.cn/file/B74lbmjHHoPHesx1znuc0iOanGe

![[flagcx support nixl backend 2026-03-11 20.24.22.excalidraw.svg]]
%%[[flagcx support nixl backend 2026-03-11 20.24.22.excalidraw.md|🖋 Edit in Excalidraw]]%%

time log：
- [ ] 确定一些未知问题
* p2p.cc 里传输不是一个“拿来即用的 memcpy helper”，它绑在 proxy/transportResources/flagcxProxyArgs，复用成本过高。。。
* 本地 registerMem -> flagcx_nixl_reg_mem -> flagcx_nixl_export_mem；远端 loadRemoteMD -> flagcx_nixl_import_mem。same-host 最多在 import 时打开一次 IPC 映射，cross-host 只保存 mem_token/base/len。如果上层每次推理都新分配临时 buffer，那会有重复注册，但那是上层生命周期问题，不是 southbound 必须 per-peer 临时注册。
* flagcx_nixl_reg_mem 返回的是“本进程私有 handle”，不能直接跨 agent 用；==而 NIXL 跨 agent 传的就是 blob==。export_mem 负责把可共享部分序列化出去，import_mem 负责在消费端变成 remote_mem 对象。same-host 时它会把 IPC handle 打开成 ipc_mapped_ptr；cross-host 时它只保留 token/range，供后续 control/data plane 用。