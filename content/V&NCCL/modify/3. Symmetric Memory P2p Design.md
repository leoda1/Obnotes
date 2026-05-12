# 0 Related work
在[[ceAlltoall的完整实现：]]内，ceAlltoall使用了对称内存来完成数据的传输。需要参考这里的同步机制来实现VCCL机内不hang。
# 1 具体实现
## 1.1 nccl内可参考部分

![[diff from 1 to 7 2025-10-13 19.50.43.excalidraw]]
## 1.2 vccl方案
### 1.2.1 Use symmetric
![[Symmetric Memory P2p Design 2025-10-15 19.19.33.excalidraw]]

# 2 排期
准备cuda13.0开发环境和测试环境一天，开发大约1-2天，debug2天。总时间4-5天。