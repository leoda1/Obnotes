## 基本概念
[[fbcdf5e2-7392-4b02-9a98-78ab107d59e9_基本概念.pdf]]
## 介绍
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20251117204543324.png)
CPU程序发送时通知RNIC，收到数据的时候也需要通知CPU。**软件硬件交互如下**：
* 首先，RDMA抽象出Send Que（SQ），Recv Que（RQ），Complete Que（CQ）来给用户。用户需要Send时，就往SQ放一个Send WQE（Work Que Element）的元素；需要Recv的时候同理。WQE内包含了数据地址和长度等信息，RNIC收到后就可以进行数据收发。由于网络的传输由硬件做，此时CPU可以进行别的任务，整个过程异步。网卡完成收发操作后，会在CQ内放一个CQE（Complete  Que Element），CPU查询CQ获取完成的信息。
* 其次，RDMA是zerocopy，bypass了kernel。用户态数据直接DMA到网卡的buffer发送，需要用户先register一块内存给网卡使用。但是用户拿到gpu memory是VA（virtual address）地址，怎么从虚拟地址对应到物理地址呢？RNIC维护了MTT（Memory Translation Table），类似操作系统的页表，维护虚拟地址到物理地址的关系。RNIC就可以对用户分配的地址读/写了。数据从gpu memory到网卡的搬运走的是DMA。
* 最后，RNIC需要维护收发报文结构，例如Receiving Buffer, ORT, Reordering Buffer, Bitmap等。

另外，还有一种就是DoorBell（DB），是一种软件发起、硬件接收的通知机制。软件常通过Doorbell告诉硬件：
* 开始：我准备好WQE，通知硬件开始处理。
* 结束：我读取了CQE，通知硬件“我已经取走了CQE”。