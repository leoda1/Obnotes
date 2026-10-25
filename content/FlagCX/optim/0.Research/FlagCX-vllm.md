### 0.前言
 记录 Flagcx 参考 pynccl_wrapper.py 实现的 flagcx_wrapper.py。vllm 就可以直接调用到 flagcx 内的 flagcx.h 内封装的底层通信接口。主要就是 在干一件事情：==用 Python ctypes 把 flagcx.h 里的 C API 原样映射出来，再把 torch.Tensor 的指针和 stream 句柄直接喂给 FlagCX==。此外 nccl 的 nccl4py 也有同样功能，见[[nccl4py| nccl4py call chain]]。
 跳过 torch.distributed 就可以实现不改动 torch，快速调用底层的通讯接口。
### 1. Flagcx的python底层通信
vllm 原始文件自己写得很直白，核心思路是：
* 不想走 torch.distributed 的高层封装；
* 也不想写死成 C/C++ 扩展；
* 直接用 ctypes 调底层通信库，方便控制 stream / communicator / graph 友好的调用路径。

Flagcx 则参考 vllm 这个封装框架 从“直连 NCCL” 变成了 “直连 FlagCX”。核心的逻辑为：
* 1. 给外部 Python 上层一个直接调用 FlagCX 的入口。
现在仓库内没看到别的文件直接 import 这层 wrapper，所以它更像是给外部项目预留的接口，而不是 FlagCX 仓库内部主流程依赖。

* 2. 对齐 vllm/推理服务常见的调用方式。
比如 communicator 初始化、all_reduce/send/recv/broadcast、group 调用、stream 绑定，这些都很像 vllm 那类推理通信需求。

* 3. 发挥 FlagCX 自己比 NCCL 更宽的抽象能力。
FlagCX 不只是 collective，还带设备抽象、事件、流、IPC 内存句柄、异构设备适配，拓宽`pynccl_wrapper.py`。

### 2. 代码原理
FLAGCXLibrary 做 C 符号导出和动态加载：
```python
class FLAGCXLibrary:
    exported_functions = [
        Function("flagcxHandleInit", flagcxResult_t,
                [ctypes.POINTER(flagcxHandlerGroup_t)]),
        Function("flagcxHandleFree", flagcxResult_t,
                [flagcxHandlerGroup_t]),
        Function("flagcxGetErrorString", ctypes.c_char_p, [flagcxResult_t]),
        Function("flagcxGetVersion", flagcxResult_t,
                 [ctypes.POINTER(ctypes.c_int)]),
        Function("flagcxGetUniqueId", flagcxResult_t,
                [ctypes.POINTER(ctypes.POINTER(flagcxUniqueId))]),
```
然后初始化时会 dlopen 动态库、绑定函数签名、再调用 flagcxHandleInit 拿到一组底层句柄：
```python
    def __init__(self, so_file: Optional[str] = None):
        try:
            if so_file not in FLAGCXLibrary.path_to_dict_mapping:
                lib = ctypes.CDLL(so_file)
                FLAGCXLibrary.path_to_library_cache[so_file] = lib
            self.lib = FLAGCXLibrary.path_to_library_cache[so_file]
        except Exception as e:
            raise e

        if so_file not in FLAGCXLibrary.path_to_dict_mapping:
            _funcs: Dict[str, Any] = {}
            for func in FLAGCXLibrary.exported_functions:
                f = getattr(self.lib, func.name)
                f.restype = func.restype
                f.argtypes = func.argtypes
                _funcs[func.name] = f
            FLAGCXLibrary.path_to_dict_mapping[so_file] = _funcs
        self._funcs = FLAGCXLibrary.path_to_dict_mapping[so_file]

        self.handler = flagcxHandlerGroup_t()
        self.FLAGCX_CHECK(self._funcs["flagcxHandleInit"](ctypes.byref(self.handler)))
```
FlagCX 自己不是只有 communicator，它还暴露设备适配层，这层 handler：
```python
struct flagcxDeviceHandle {
  // Basic functions
  flagcxResult_t (*deviceSynchronize)();
  flagcxResult_t (*deviceMemcpy)(void *dst, void *src, size_t size,
                                 flagcxMemcpyType_t type,
                                 flagcxStream_t stream);
  ...
  flagcxResult_t (*getVendor)(char *vendor);
  flagcxResult_t (*hostGetDevicePointer)(void **pDevice, void *pHost);
  // Stream functions
  flagcxResult_t (*streamCreate)(flagcxStream_t *stream);
  ...
  // Event functions
  flagcxResult_t (*eventCreate)(flagcxEvent_t *event,
                                flagcxEventType_t eventType);
  ...
  // IpcMemHandle functions
  flagcxResult_t (*ipcMemHandleCreate)(flagcxIpcMemHandle_t *handle,
                                       size_t *size);
  ...
};
typedef struct flagcxDeviceHandle *flagcxDeviceHandle_t;

struct flagcxHandlerGroup {
  flagcxUniqueId_t uniqueId;
  flagcxComm_t comm;
  flagcxDeviceHandle_t devHandle;
};
```
调用链：
* 1. flagcxGetUniqueId() 生成通信域 ID。
* 2. 把这个 ID 用外部通道广播/传给别的 rank。
    这也是后来补 unique_id_from_bytes() 的原因，方便跨进程/跨服务重建 unique_id。
* 3. 每个 rank 调 flagcxCommInitRank() 建 communicator。
* 4. 把 torch.dtype / ReduceOp 映射成 flagcx 枚举。
* 5. 把 tensor.data_ptr() 和 stream.cuda_stream 对应的底层句柄传给 flagcxAllReduce / flagcxSend / flagcxRecv 等函数。
如下：
```python
    def flagcxGetUniqueId(self) -> flagcxUniqueId:
        unique_id = ctypes.POINTER(flagcxUniqueId)()
        self.FLAGCX_CHECK(self._funcs["flagcxGetUniqueId"](
            ctypes.byref(unique_id)))
        return unique_id

    def unique_id_from_bytes(self, data: bytes) -> flagcxUniqueId:
        if len(data) != 256:
            raise ValueError(
                f"Expected 256 bytes for ncclUniqueId, got {len(data)} bytes")
        unique_id = flagcxUniqueId()
        ctypes.memmove(ctypes.addressof(unique_id.internal), data, 256)
        return unique_id

    def flagcxCommInitRank(self, world_size: int, unique_id: flagcxUniqueId,
                         rank: int) -> flagcxComm_t:
        comm = flagcxComm_t()
        self.FLAGCX_CHECK(self._funcs["flagcxCommInitRank"](ctypes.byref(comm),
                                                        world_size, unique_id,
                                                        rank))
        return comm
...
    def flagcxAllReduce(self, sendbuff: buffer_type, recvbuff: buffer_type,
                      count: int, datatype: int, op: int, comm: flagcxComm_t,
                      stream: flagcxStream_t) -> None:
        self.FLAGCX_CHECK(self._funcs["flagcxAllReduce"](sendbuff, recvbuff, count,
                                                     datatype, op, comm,
                                                     stream))
```
**综上，外部 vllm可以直接调 FlagCX 做 communicator 初始化、collective、P2P、stream/event/IPC 管理，尤其适合需要绕开高层框架通信封装的场景。**