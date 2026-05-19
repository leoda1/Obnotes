## 1. Intro
### 1.1 call chain
```python
Python: nccl_comm.reduce(data, data, nccl.SUM)
    ↓
Python: communicator.py::reduce() 
    ↓ (root=None → all_reduce)
Cython: nccl.pyx::all_reduce()
    ↓
Cython: cynccl.pyx::ncclAllReduce()
    ↓
Cython: _internal/nccl_linux.pyx::_ncclAllReduce()
    ↓ (通过 dlsym 获取函数指针)
C 库: libnccl.so::ncclAllReduce()
    ↓
GPU 通信执行
```
**从 Python 调用开始，经过 Python 包装 → Cython 绑定 → 动态库加载 → NCCL C 库，最终在 GPU 上执行通信操作。**
### 1.2 compile and test
* step1. VCCL/nccl4py路径下直接编译(==主 node 执行==就可以完成 nccl4py的编译，如果缺少包就自己看缺啥 pip install 啥)：
```shell
export CUDA_HOME=/usr/local/cuda
python setup.py build_ext --inplace
```
* step2. 手动pip download了nccl4py需要的 python 依赖，比如  `cuda.core` 等来应对集群没有网的 case。主要包括一下四个：
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20260306135427704.png)
写一个 `requirements.txt` 一键 pip install 这些 whl 轮子。
```
pip3 config set global.index-url http://nexus.sii.shaipower.online/repository/pypi/simple/ 
pip3 config set global.trusted-host nexus.sii.shaipower.online
# requirements.txt
pip install packaging==24.2
pip install mpi4py cuda.core
```
安装（==每个 node 上执行==）：
```
cd nccl4py
pip install -r requirements.txt --no-index --find-links=./third/
```
* step3. 完成安装后直接就可以使用 vccl alltoallv 简单测试`03_alltoallv.py`的功能：
```shell
export PYTHONPATH=/inspire/hdd/global_user/huxiaohe-p-huxiaohe/liuda/a2av/nccl4py/build:$PYTHONPATH
export LD_LIBRARY_PATH=/inspire/hdd/global_user/huxiaohe-p-huxiaohe/liuda/a2av/build/lib:$LD_LIBRARY_PATH
mpirun -np 4 \
        --allow-run-as-root \
        -x LD_LIBRARY_PATH=/workspace/liuda/iw/VCCL/build/lib:$LD_LIBRARY_PATH \
        python examples/01_basic/03_alltoallv.py
```
发包
```shell

```
## 2. VCCL AlltoallV 4py
目前C++接口为:
```cpp
ncclResult_t ncclAlltoAllv(const void* sendbuff, const size_t* sendcounts,
    const size_t* sdispls, void* recvbuff, const size_t* recvcounts, const size_t* rdispls,
    const void* relaybuff, ncclDataType_t datatype, ncclComm_t comm, cudaStream_t stream);
ncclResult_t pncclAlltoAllv(const void* sendbuff, const size_t* sendcounts,
    const size_t* sdispls, void* recvbuff, const size_t* recvcounts, const size_t* rdispls,
    const void* relaybuff, ncclDataType_t datatype, ncclComm_t comm, cudaStream_t stream);
```
python接口为：
```python
def alltoallv(
        self,
        sendbuf: NcclBufferSpec,
        recvbuf: NcclBufferSpec,
        sendcounts: Sequence[int],
        sdispls: Sequence[int],
        recvcounts: Sequence[int],
        rdispls: Sequence[int],
        relaybuf: NcclBufferSpec | None = None,
        *,
        stream: NcclStreamSpec | None = None,
    ) -> None:
```
**这里count和displs都是nRanks<sup>2</sup>的长度，每个rank能找到自己发给目的rank的长度和起始地址**

## 3. test example
vccl alltoallv的测试脚本路径为： `VCCL/nccl4py/examples/01_basic/03_alltoallv.py`

## 4. optim
* 优化 alltoallv python-->c++之间的 cpu 调用，主要是 nccl4py/nccl/core/communicator.py 
  * check_valid, 检查 comm 是不是空，==可以删==
  * NcclBuffer(sendbuff)和NcclBuffer(recvbuff)，把 tensor 变成 NcclBuffer 对象
    * 改动 1. 内部调用_torch_to_nccl(每次都回去构建一个_unsupported_dtypes表)，现在直接==缓存一次==这个表，每次 get 一下。
    * 改动 2. 在上层就知道三个 buffer 的类型，所以==直接在上层调用一次==_to_nccl_dtype给到三个 buffer。
  * _validate_buffer_device 可以直接==删掉==
  * 类型转化理论上最优==还可以收敛到== python list 用一次 np 转成 uintp（size_t*）丢给 c++
