---

---
# 1. nccltest数据初始化

```c++
testResult_t AlltoAllInitData(struct threadArgs* args, ncclDataType_t type, ncclRedOp_t op, int root, int rep, int in_place) {
  size_t sendcount = args->sendBytes / wordSize(type);
  size_t recvcount = args->expectedBytes / wordSize(type);
  int nranks = args->nProcs*args->nThreads*args->nGpus; // 计算总rank数量
  
  for (int i=0; i<args->nGpus; i++) {
    CUDACHECK(cudaSetDevice(args->gpus[i]));
    int rank = ((args->proc*args->nThreads + args->thread)*args->nGpus + i); // 计算当前rank
    CUDACHECK(cudaMemset(args->recvbuffs[i], 0, args->expectedBytes));
    void* data = in_place ? args->recvbuffs[i] : args->sendbuffs[i];
    for (int j=0; j<nranks; j++) {
      size_t partcount = sendcount/nranks;
      TESTCHECK(InitData((char*)data + j * partcount * wordSize(type), partcount, j * sendcount, type, ncclSum, 33*rep + rank, 1, 0));
      TESTCHECK(InitData((char*)args->expected[i] + j*partcount*wordSize(type), partcount, j * partcount, type, ncclSum, 33*rep + j, 1, 0));
    }
    CUDACHECK(cudaDeviceSynchronize());
  }
  // We don't support in-place alltoall
  args->reportErrors = in_place ? 0 : 1;
  return testSuccess;
}
```

核心点在于：args是结构体，其中的

1. 总的rank数：nranks = 进程总数 * 线程总数 * GPU总数
2. 当前rank index：（当前进程index * 线程总数 + 当前线程index ）* GPU总数 + 当前GPU index

# 2. 文档对GroupStart和GroupEnd的规定

3. [CUDA Stream Semantics — NCCL 2.26.2 documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/usage/streams.html)，nccl允许在群组通话中使用多个流。这将在 NCCL 内核启动之前强制所有流相互依赖，并在 NCCL 内核完成之前阻止所有流
4. 当单个线程管理多个设备时，必须使用组语义。还有Stream operations like cudaStreamSynchronize can therefore be called only after ncclGroupEnd returns。[Group Calls — NCCL 2.26.2 documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/usage/groups.html#management-of-multiple-gpus-from-one-thread)
5. NCCL 操作仅在最后一次调用 ncclGroupEnd 时才会整体启动。[Group Calls — NCCL 2.26.2 documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/usage/groups.html#management-of-multiple-gpus-from-one-thread)
6. 同一组内的点对点调用将处于阻塞状态，直到该组调用完成为止。但同一组内的调用可以视为独立进行，因此不应相互阻塞。因此，合并需要并发进行的调用以避免死锁非常重要。[Point-to-point communication — NCCL 2.26.2 documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/usage/p2p.html)
7. **非阻塞组操作**
[https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/usage/groups.html#management-of-multiple-gpus-from-one-thread](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/usage/groups.html#management-of-multiple-gpus-from-one-thread)