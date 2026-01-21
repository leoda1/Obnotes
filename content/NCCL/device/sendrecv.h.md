
```cpp
 if (isCopy) {
      reduceCopy<COLL_UNROLL, RedOp, T, 0,1,1, 0,1,1, /*PreOpSrcs=*/0>
        (subtid, subtn, 0, nullptr, false, 1, &work->sendAddr, 1, &work->recvAddr, (ssize_t)work->sendBytes);
    } else if (isSend) {
      if (work->sendProtoLL) {
        runSend<ProtoLL>(subtid, subtn, group, work);
      } else {
        if (tid == 0) printf("GPU Kernel: Executing isSend path\n");
        runSend<ProtoSimple<1,1>>(subtid, subtn, group, work);
      }
    } else {
      if (work->recvProtoLL) {
        runRecv<ProtoLL>(subtid, subtn, group, work);
      } else {
        if (tid == 0) printf("GPU Kernel: Executing recv path\n");
        runRecv<ProtoSimple<1,1>>(subtid, subtn, group, work);
      }
    }
```
