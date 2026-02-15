## 1. 概述
### a. Megatron
* [Buffer](https://infrawaves.feishu.cn/wiki/Cscdw9sF8iDntlknRFocHRFNnrc?fromScene=spaceOverview) 的创建，这个部分需要提前创建出来对称内存提供给permute+layout部分使用。
* permute+layout部分的流程为[[token dispatcher + fuse_a2a]]
### b. NCCL4PY
* 涉及内存alloc和vccl alltoallv的c++接口怎么直接给上层使用 [[nccl4py]]
### c. VCCL
* 完整的无核alltoallv的开发[[vccl alltoallv dev log]]
* 
### d. VCCL Document
* 简洁明了的对外说明and [[sm-free alltoallv for moe training]]

## 2. timeline
- [x] 过一遍当前进度，弄清楚现在的buffer设计：[vccl moe in feishu](https://infrawaves.feishu.cn/wiki/Oi8twqYNLizawSk0LCPcCpQen4b) 🛫 2026-01-14 ✅ 2026-01-15
- [x] 增加alltoallv接口，修改sendcounts/recvcounts为指针，增加relay_buffer和它的长度，直接使用nccl4py调用，设计开发测试 🛫 2026-01-15 ✅ 2026-01-16
- [x] layout部分完成input/output split正确写到sendcounts/recvcounts内，第一行保存每个rank自己在input buffer的长度，第二行保存每个rank自己在input buffer上的开始地址。 ✅ 2026-01-16
- [x] taskAppend to planner  ✅ 2026-01-27
- [x] scheduleRmaTaskToPlan调度：1234(signal) 5(signal)6(signal)7(signal) ✅ 2026-01-29
    - [x] 按Node算调度逻辑。不按group整了（前面要拿的信息封到一个struct里面由一个func返回）。 ✅ 2026-01-27
    - [x] 主for loop以batch来，不按group来。 ✅ 2026-01-27
    - [x] batchWork在for loop里创建&enqueue(ncclMemoryStackAlloc) ✅ 2026-01-28
    - [x] 考虑batch为空的情况，跳过 ✅ 2026-01-28
    - [x] phase1 and phase4内考虑relaybuff切换 ✅ 2026-01-29
    - [x] 每个batch里面的所有CeWait合并成一个，所有的ProxyWait合并成1个 ✅ 2026-01-29
    - [x] 完成self-copy，phase1-4的所有调度 ✅ 2026-01-29
    - [x] delta从0开始 ✅ 2026-01-29
- [ ] 如何在另一个ctx内增加proxyPut/proxyWait来让relaybuffer不会机间影响机内