## 问题1: DCI，DCT都是啥
在RC（Reliable Connection ）中每个节点要建立一对QP，如果N节点就需要N-1个连接。规模越大，QP越多连接越慢。于是出现Dynamic Connected Transport（DC）机制。
### 0. 核心思想
>传统RC：每个连接都是一对固定的QP。
```txt
Rank0 QP ↔ Rank1 QP
Rank0 QP ↔ Rank2 QP
Rank0 QP ↔ Rank3 QP
```
> DC模型：共享资源，动态绑定：
```txt
Rank0 DCI (sender)
        ↕   (connect on demand)
Rank1 DCT (receiver)
Rank2 DCT
Rank3 DCT
```
* receiver一直提供多个DCT(Dynamic Connection  Target)，sender发送时刻才会借用一个DCI（Dynamic Connection Initiator）来连接上下文发送数据
* **发送完DCI释放**
在NVSHMEM内，像：
```cpp
nvshmemi_ibgda_device_qp_t *dcis;  // Dynamic Connection Initiators
nvshmemi_ibgda_device_dct_t *dcts; // Dynamic Connection Targets
```
* `dcis`:device侧可以向随意一个peer发起RDMA操作
* `dcts`: 接收任意peer的请求
* NVSHMEM需要做的是去维护这个DCI调度表（“**round-robin or hash**”）来复用`DCI`。
### 1. 实现
step1. receiver创建DCT
```cpp
struct ibv_qp_init_attr_ex attr = {
    .qp_type = IBV_QPT_DRIVER, // or IBV_QPT_DC_INI for DCI
    ...
};
ibv_create_dct(ctx, &attr);
```

step2.sender创建DCI QP
```cpp
attr.qp_type = IBV_QPT_DC_INI;
qp = ibv_create_qp_ex(ctx, &attr);
```

step3.发送时，DCI会在发送的package的header上指定目标的DCT的QPN，hardware automatic完成地址绑定（不需要提前建立连接）

step4. 接收端DCT收包，接收并response，无需提前建立对等连接。
## 问题2: RC端点和QP的创建关系
### 0. 结论
nvshmem内的endpoint就是端点，**RC端点**等价于 **一个已建立连接的RC QP，在一个endpoint内会包含：QP，CQ，地址信息（LID/GID），PSN、QPN、状态机等数据**。
### 1. 从RDMA 协议层理解
在RDMA verbs内，最核心的就是QP，一对QP就是一条可靠的RC，就是：
```cpp
struct ibv_qp {
    struct ibv_cq *send_cq;
    struct ibv_cq *recv_cq;
    uint32_t qpn;      // Queue Pair Number
    ...
};
```
> 一对 QP（本地 + 远端） = 一条可靠通信通道（RC）。

### 2. nvshmem内的ibgda_setup_rc_endpoints
1. 创建多个QP
2. 给这些QP分配和绑定CQ
3. 初始化QP的属性（RESET->INIT）
4. **和peer交换**（bootstrap？？回头确定一下）连接信息（LID，GID，QPN）
5. 调用`ibv_modify_qp()` 把 QP 转入 RTR / RTS 状态
6. 保存为`device->rc.eps[i]` 数组（每个 peer 一个 endpoint）
