### 1. Entrance
`ncclKernelPlan` 内需要增加一个结构体字段的指针，这个结构体内包含前置的ready（无核的progress开始执行的条件）和后置的proxyOpCount（无核的progress结束就减少当前计数）。 finishPlann内new出这个结构体，如下，给到 `ncclKernelPlan` 内的这个指针（防止资源回收）。
```cpp
struct psmSyncCondition {
  std::atomic<int>* proxyOpCount;    // The total number of proxyOp's that have been enqueued in this plan.
  std::atomic<int>* proxyReadyEvent; // Event that proxy thread queries for starting progresssing.
  bool proxyReadyEventSet;           // true if the proxyReadyEvent has been set
};
```
给到 `ncclKernelPlan` 内的就是：
```cpp
struct ncclKernelPlan {
	...
	struct psmSyncCondition* syncCondition;
	...
}
```
在 `finishPlan` 内的给无核的任务new出这个Sync Condition。
```cpp
if (ncclParamPassSm()) {
    plan->syncCondition = new psmSyncCondition;

    plan->syncCondition->proxyReadyEvent = new std::atomic<int>(0);
    plan->syncCondition->proxyOpCount= new std::atomic<int>(proxyOpCnt);
    plan->syncCondition->proxyReadyEventSet = false;
  }
```
### 2. Lauch stage
`ncclLaunchKernel` 内对于无核的任务就是：
```cpp
if (ncclParamPassSm() &&
      plan->kernelFn == ncclDevKernelForFunc[ncclDevFuncId_P2p()]) {
    // Launching a cudaHostFunc() to pass sm.
    CUDACHECKGOTO(cudaLaunchHostFunc(launchStream, hostProxySyncCallback, plan->syncCondition), ret, do_return);
    goto do_return;
  }
```
hostfunc将这里的plan->syncCondition这个结构里面的proxyReadyEvent这个原子store为1, 然后底层的progress就会看到这个1开始他们的搬运操作。完成一个args就会相应的给proxyOpCount减掉nsubs的计数。如果会等到 `proxyOpCount` 变为0，告诉launchStream现在是这个host的任务完成了。
### 3. Progress
在实际的proxy搬运数据的时候，不管是net还是p2p，只需在进progress的时候：
```cpp
if(!args->readyEvent->load(std::memory_order_acquire)) return ncclSuccess;
```
