## 1. nvshmemi_ibgda_put_nbi_warp
### 函数签名
```cpp
template <bool kAlwaysDoPostSend = false>
__device__ static __forceinline__ void nvshmemi_ibgda_put_nbi_warp(
    uint64_t req_rptr, uint64_t req_lptr, size_t bytes, int dst_pe, int qp_id, int lane_id, int message_idx);
```
* req_rptr ← dst_ptr（上面计算的远端地址，即接收端缓冲区的绝对地址）。
* req_lptr ← src_ptr 或 rdma_x_src_idx / buf_ptr（源数据在本地内存/发送缓冲区的地址）。
* bytes ← num_bytes_per_msg（单条消息的字节长度，由 hidden、meta 等字段计算出来）。
* dst_pe ← dst_rank（远端 PE / rank）。
* qp_id ← dst_expert_local_idx（选择用于和远端通信的 RC QP 的 id，通常按目标本地专家索引选 QP，便于并发）。
* lane_id ← lane_id（warp 中的 lane，0..31）。内部把不同 lane 用来并行构造多条 WQE（把大消息分 chunk 并分配给 lanes）。
* message_idx ← slot_idx（或在 combine/send 场景中传 token_idx - offset 作为消息索引）。该参数被传给 ibgda_submit_requests 用于决定何时调用 doorbell（post send）策略 / 批次逻辑。
### 传输
首先就是会把数据分块，一次 RDMA 操作不能跨越不同的 MR。把总的bytes数按照[ibgda_get_lkey_and_rkey](##2.ibgda_get_lkey_and_rkey)的规则来切分。
```cpp
auto remaining_bytes = bytes;
    while (remaining_bytes > 0) {
        if (lane_id == num_wqes) {
            my_chunk_size = min(remaining_bytes,
                                ibgda_get_lkey_and_rkey(my_laddr = req_lptr, &my_lkey, req_rptr, dst_pe, &my_raddr, &my_rkey, qp->dev_idx));
        }

        // 广播给warp内所有lane
        auto chunk_size = __shfl_sync(0xffffffff, my_chunk_size, static_cast<int>(num_wqes));
        remaining_bytes -= chunk_size;
        req_lptr += chunk_size;
        req_rptr += chunk_size;
        ++num_wqes;// WQE 数量 +1
    }
```
接着，开始构造每个WQE，见[ibgda_write_rdma_write_wqe](##3.ibgda_write_rdma_write_wqe)实现。
```cpp
uint64_t base_wqe_idx = 0;
if (lane_id == 0)
    base_wqe_idx = ibgda_reserve_wqe_slots(qp, num_wqes);  // 预留连续的 WQE 槽位
base_wqe_idx = __shfl_sync(0xffffffff, base_wqe_idx, 0);   // 广播给所有 lanes

if (lane_id < num_wqes) {
    auto wqe_idx = base_wqe_idx + lane_id;
    auto wqe_ptr = ibgda_get_wqe_ptr(qp, wqe_idx);  // 获取 WQE 的内存地址
    ibgda_write_rdma_write_wqe(
        qp, 
        my_laddr, my_lkey,      // 本地地址 + lkey
        my_raddr, my_rkey,      // 远程地址 + rkey
        my_chunk_size,          // 传输字节数
        wqe_idx,                // WQE 索引
        &wqe_ptr                // WQE 内存地址
    );
}
```
构造完毕后，会用syncwarp，同步每个warp。每个warp的第一个线程把所有WQE提交给rdma，详细见[ibgda_submit_requests](##4.ibgda_submit_requests)：
```cpp
if (lane_id == 0)
        ibgda_submit_requests<kAlwaysDoPostSend>(qp, base_wqe_idx, num_wqes, message_idx);
```
### 总体流程
```txt
┌─────────────────────────────────────────────────────────────┐
│  nvshmemi_ibgda_put_nbi_warp(req_rptr, req_lptr, bytes, ...)│
└────────────────────┬────────────────────────────────────────┘
                     │
        ┌────────────▼────────────────────┐
        │ 1. 计算分块（Chunking）           │
        │   - 遍历剩余字节                  │
        │   - 每个 lane 计算一个 chunk      │
        │   - 调用 ibgda_get_lkey_and_rkey │
        └────────────┬────────────────────┘
                     │
        ┌────────────▼──────────────────────┐
        │ ibgda_get_lkey_and_rkey           │
        │  - 查找本地 lkey（constmem.lkeys）  │
        │  - 查找远程 rkey（constmem.rkeys）  │
        │  - 计算物理地址                     │
        │  - 返回 chunk 大小                 │
        └────────────┬──────────────────────┘
                     │
        ┌────────────▼─────────────────┐
        │ 2. 预留 WQE 槽位               │
        │   - lane 0 调用 atomicAdd     │
        │   - 广播 base_wqe_idx         │
        └────────────┬─────────────────┘
                     │
        ┌────────────▼───────────────────┐
        │ 3. 构造 WQE（并行）              │
        │   - 每个 lane < num_wqes 填充   │
        │   - ibgda_write_rdma_write_wqe │
        │     * Control Segment          │
        │     * Remote Address Segment   │
        │     * Data Segment             │
        └────────────┬───────────────────┘
                     │
        ┌────────────▼────────────────┐
        │ 4. 提交 WQE                  │
        │   - __threadfence()         │
        │   - atomicCAS ready_idx     │
        │   - ibgda_post_send         │
        │     * ibgda_update_dbr      │
        │     * ibgda_ring_db         │
        └────────────┬────────────────┘
                     │
        ┌────────────▼────────────────┐
        │ 5. NIC 硬件执行 RDMA Write   │
        │   - 读取 WQE                │
        │   - DMA 从 laddr 读取数据    │
        │   - 通过 IB 网络发送          │
        │   - 远端 NIC 写入 raddr      │
        └────────────┬────────────────┘
                     │
        ┌────────────▼──────────────┐
        │ 6. 完成通知（CQE）          │
        │   - NIC 写入 CQ            │
        │   - nvshmemi_ibgda_quiet  │
        │     轮询 CQ 等待完成        │
        └───────────────────────────┘
```

## 2. ibgda_get_lkey_and_rkey
输入本地和远程的VA，拿到lkey,rkey,物理地址和chunksize。

## 3. ibgda_write_rdma_write_wqe
填充对端的字段：
```cpp
raddr_seg.raddr = HtoBE64(raddr);  // 远程物理地址（大端序）
raddr_seg.rkey = rkey;             // 远程 rkey
```
填充本地的数据字段：
```cpp
data_seg.byte_count = HtoBE32(bytes);  // 传输字节数
data_seg.lkey = lkey;                  // 本地 lkey
data_seg.addr = HtoBE64(laddr);        // 本地地址
```
填充控制信号的字段：
```cpp
ctrl_seg.qpn_ds = HtoBE32((qp->qpn << 8) | 3);  // QP 编号 + DS（段数量）
ctrl_seg.fm_ce_se = MLX5_WQE_CTRL_CQ_UPDATE;    // 完成时更新 CQ
ctrl_seg.opmod_idx_opcode = HtoBE32((wqe_idx << 8) | MLX5_OPCODE_RDMA_WRITE);  // 操作码：RDMA Write
```
然后把上面三个结构体写入到WQE memory:
```cpp
st_na_relaxed(reinterpret_cast<int4*>(ctrl_seg_ptr), *reinterpret_cast<const int4*>(&ctrl_seg));
    st_na_relaxed(reinterpret_cast<int4*>(raddr_seg_ptr), *reinterpret_cast<const int4*>(&raddr_seg));
    st_na_relaxed(reinterpret_cast<int4*>(data_seg_ptr), *reinterpret_cast<const int4*>(&data_seg));
```
## 4. ibgda_submit_requests
step1:内存屏障
```cpp
__threadfence();  // 确保所有 WQE 写入对 NIC 可见
```
step2:原子级更新ready_idx
```cpp
unsigned long long int* ready_idx = state->use_async_postsend ? 
    qp->tx_wq.prod_idx : &mvars->tx_wq.ready_head;

while (atomicCAS(ready_idx, base_wqe_idx, new_wqe_idx) != base_wqe_idx)
    ;  // 等待之前的 WQE 都被填充完毕
```
step3:通过CAS循环，可以让多个warp按照顺序提交。然后再去写入doorbell，NIC就会知道有新的WQE需要处理。（doorbell是特殊的内存映射寄存器，MMIO）NIC会从Send Queue取出WEQ执行RDMA操作。
```cpp
if (!state->use_async_postsend) {
        constexpr int kNumRequestInBatch = 4;
        if (kAlwaysDoPostSend or (message_idx + 1) % kNumRequestInBatch == 0)
            ibgda_post_send(qp, new_wqe_idx);
    }
```
在ibgda_post_send内会去更新 DBREC，再写入 BlueFlame 寄存器。再之后NIC 硬件执行 RDMA Write(DMA 从 laddr 读取数据->过 IB 网络发送->远端NIC写入raddr)，完成时NIC写入CQ，外面会用nvshmemi_ibgda_quiet来轮询CQ完成状态。
```cpp
__device__ static __forceinline__ void ibgda_post_send(nvshmemi_ibgda_device_qp_t* qp, uint64_t new_prod_idx) {
    nvshmemi_ibgda_device_qp_management_t* mvars = &qp->mvars;
    uint64_t old_prod_idx;
    ibgda_lock_acquire(&mvars->post_send_lock);

    old_prod_idx = atomicMax(reinterpret_cast<unsigned long long int*>(&mvars->tx_wq.prod_idx), new_prod_idx);
    if (new_prod_idx > old_prod_idx) {
        // 1. 更新 DBREC（Doorbell Record）
        ibgda_update_dbr(qp, new_prod_idx);
        // 2. Ring Doorbell（写入 BlueFlame 寄存器）
        ibgda_ring_db(qp, new_prod_idx);
    }
    ibgda_lock_release(&mvars->post_send_lock);
}
```