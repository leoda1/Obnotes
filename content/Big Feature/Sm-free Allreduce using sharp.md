# 0 前言
核心问题，我怎么能结合NCCL的device API，实现占用极少SM的kernel（PTX实现的）或者完全不占用SM的方法去把Allreduce的规约放到NVSwitch sharp内做，data transmission依旧使用cudaMemcpyAsync/cudaMemcpyBatchAsync。
# 1 PTX的基本语法
CUDA与PTX关系：
https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#ptx-compatibility
PTX:
https://docs.nvidia.com/cuda/parallel-thread-execution/#goals-of-ptx

# 2 NCCL给的参考
## 2.1 PTX Programming
Within the device kernel, we can switch the memory barrier to a multimem-optimized variant by adding an extra argument to the constructor. The processing loop is actually simpler with multimem: ncclGetLsaMultimemPointer() needs to be invoked just once per kernel. The returned multicast memory pointer enables access to the device memory of all the ranks of the communicator without having to iterate over them, and the data can be reduced in hardware. To keep this example simple, the implementations of multimem_sum and multimem_st are not included. Those need to be implemented using PTX, e.g., multimem.ld_reduce.global.add and multimem.st.global.
nccl给的参考：
https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/usage/deviceapi.html
如何使用这里给的参考的ptx接口操纵NVSwitch，去解决SM-Free的AR的规约计算，例如 `multimem.ld_reduce`。
https://docs.nvidia.com/cuda/parallel-thread-execution/#data-movement-and-conversion-instructions

[[Parallel Thread Execution(PTX) Programming Guide]]
## 2.2 NCCL AR logic
NVIDIA Sylvain Jeaugey在paper（Demystifying NCCL: An In-depth Analysis of GPU Communication Protocols and Algorithms）的allreduce实现。
ring allreduce:
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250930204758464.png)
tree allreduce:
![image.png](https://liuda-1370225914.cos.ap-beijing.myqcloud.com/obsidian/picgo/20250930204823052.png)
nvls allreduce:
Sylvain Jeaugey对nvls的解释很简短，具体的原理并没有在文中说明。支持NVSwitch上支持sharp的包括nvls和nvls tree，都是Simple协议。其中nvls的大致图例如下：
![[Sm-free Allreduce using sharp 2026-01-29 20.44.25.excalidraw.svg]]
%%[[Sm-free Allreduce using sharp 2026-01-29 20.44.25.excalidraw.md|🖋 Edit in Excalidraw]]%%
 NVLS的规约走CollNet和sharp switch，然后NVLS Tree走fan-out。具体的如下:
* CollnetDirect is alltoall within the node and Collnet between nodes.
* CollnetChain is a chain within the node and Collnet between nodes.
* NVLS is NVLink SHARP within the node and Collnet between nodes.
* NVLSTree is NVLink SHARP within the node and Tree between nodes.
 参考： https://github.com/NVIDIA/nccl/issues/919
 
现在需要彻底弄明白nvls/nvls tree下AR在代码层面intranode内的sharp的实现，机间的collNet先放着。
[[NVLS && NVLS Tree AllRuduce]]