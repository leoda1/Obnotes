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
Makefile内的dev分支，可以看到如果需要使用nccl4py需要针对不同的cuda版本下载一些依赖，所以直接手动pip install了一些小依赖，比如  `cuda.core` 等。
然后nccl4py路径下直接编译：
```shell
export CUDA_HOME=/usr/local/cuda
python setup.py build_ext --inplace
```
测试：
```shell
export PYTHONPATH=/workspace/liuda/iw/VCCL/nccl4py/build:$PYTHONPATH
export LD_LIBRARY_PATH=/workspace/liuda/iw/VCCL/build/lib:$LD_LIBRARY_PATH
mpirun -np 4 \
        --allow-run-as-root \
        python examples/01_basic/03_alltoallv.py
```
发包
```shell

```
## 2. VCCL AlltoallV 4py

