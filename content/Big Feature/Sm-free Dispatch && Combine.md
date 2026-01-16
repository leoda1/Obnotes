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
* 简洁明了的对外说明and使用doc [[sm-free alltoallv for moe training]]

## 2. timeline
- [x] 过一遍当前进度，弄清楚现在的buffer设计：[vccl moe in feishu](https://infrawaves.feishu.cn/wiki/Oi8twqYNLizawSk0LCPcCpQen4b) 🛫 2026-01-14 ✅ 2026-01-15
- [x] 增加alltoallv接口，修改sendcounts/recvcounts为指针，增加relay_buffer和它的长度，直接使用nccl4py调用，设计开发测试 🛫 2026-01-15 ✅ 2026-01-16
- [x] layout部分完成input/output split正确写到sendcounts/recvcounts内，第一行保存每个rank自己在input buffer的长度，第二行保存每个rank自己在input buffer上的开始地址。 ✅ 2026-01-16
- [ ] 需要开一块足够大的buffer去确保input / relay / output三者在所有gpu上的偏移一致，满足condition{1: 所有gpu的sendbuff开始地址 - input buffer开始地址是相等的}