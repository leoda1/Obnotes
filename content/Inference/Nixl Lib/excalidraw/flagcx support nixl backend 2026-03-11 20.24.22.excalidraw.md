---

excalidraw-plugin: parsed
tags: [excalidraw]

---
==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠== You can decompress Drawing data with the command palette: 'Decompress current Excalidraw file'. For more info check in plugin settings under 'Saving'

# 1

```mermaid
flowchart LR
  %% =========================
  %% Agent A
  %% =========================
  subgraph A["Agent A"]
    direction TB

    subgraph A1["NIXL 侧改动"]
      AAgent["nixlAgent"]
      APlugin["libplugin_flagcx.so\nflagcx_plugin.cpp"]
      ABackend["nixlFlagcxEngine\nflagcx_backend.h/.cpp\nsupportsRemote=true\nsupportsLocal=false\nsupportsNotif=true"]
      AMD["nixlFlagcxBackendMD\nLOCAL_REG / REMOTE_IMPORTED"]
      AReq["nixlFlagcxReqH\nPREPARED / POSTED / COMPLETED"]
    end

    subgraph A2["FlagCX 侧改动"]
      ASB["flagcx_nixl_engine\nflagcx_nixl_engine.h/.cc"]
      AConn["peer cache / conn state"]
      AMem["local_mem / remote_mem"]
      AProg["accept_thread\nprogress_thread"]
      ACtrl["same-host ctrl block\nshm ring / notif / error / close"]
      ADev["deviceAdaptor\nipcMemHandleCreate/Open/Close\n deviceMemcpy"]
      ANet["netAdaptor\nctrl/data comm\nisend/irecv/test"]
    end

    AAgent --> APlugin --> ABackend --> ASB
    ABackend --> AMD
    ABackend --> AReq
    ASB --> AConn
    ASB --> AMem
    ASB --> AProg
    ASB --> ACtrl
    ASB --> ADev
    ASB --> ANet
  end

  %% =========================
  %% Agent B
  %% =========================
  subgraph B["Agent B"]
    direction TB

    subgraph B1["NIXL 侧改动"]
      BAgent["nixlAgent"]
      BPlugin["libplugin_flagcx.so"]
      BBackend["nixlFlagcxEngine"]
      BMD["nixlFlagcxBackendMD"]
      BReq["nixlFlagcxReqH"]
    end

    subgraph B2["FlagCX 侧改动"]
      BSB["flagcx_nixl_engine"]
      BConn["peer cache / conn state"]
      BMem["local_mem / remote_mem"]
      BProg["accept_thread\nprogress_thread"]
      BCtrl["same-host ctrl block"]
      BDev["deviceAdaptor"]
      BNet["netAdaptor"]
    end

    BAgent --> BPlugin --> BBackend --> BSB
    BBackend --> BMD
    BBackend --> BReq
    BSB --> BConn
    BSB --> BMem
    BSB --> BProg
    BSB --> BCtrl
    BSB --> BDev
    BSB --> BNet
  end

  %% =========================
  %% Metadata / lifecycle
  %% =========================
  ABackend -. "1. getConnInfo()" .-> ASB
  ASB -. "connInfo blob\nversion/agent/host_hash/device_id/\nctrl_desc/net listen handle" .-> BBackend
  BBackend -. "2. loadRemoteConnInfo()" .-> BSB

  BBackend -. "registerMem()\nflagcx_nixl_reg_mem()" .-> BSB
  BSB -. "public md blob\nmem_token/base/len/type/\noptional ipc_handle" .-> ABackend
  ABackend -. "loadRemoteMD()\nflagcx_nixl_import_mem()" .-> ASB

  AAgent -->|"3. connect(remote_agent)"| ABackend
  ABackend -->|"flagcx_nixl_connect()"| ASB
  ASB --> T{"Topology?"}

  T -->|"same-host"| SH["导入 peer ctrl block\nremote md 打开 IPC handle\nremote_mem.ipc_mapped_ptr ready"]
  T -->|"cross-host"| CH["建立 ctrl_send/recv_comm\n建立 data_send/recv_comm"]

  %% =========================
  %% Transfer path
  %% =========================
  AAgent -->|"4. prepXfer()"| ABackend
  ABackend -->|"组装 iov\nlocal_offset / remote_offset"| AReq
  AAgent -->|"5. postXfer()"| ABackend
  ABackend -->|"flagcx_nixl_submit(op, iovs)"| ASB

  SH --> SHPath["same-host data path\nWRITE: memcpy(remote_ptr+off, local_ptr+off)\nREAD:  memcpy(local_ptr+off, remote_ptr+off)"]
  CH --> CHPath["cross-host data path\nWRITE: WRITE_REQ -> READY -> isend -> DONE\nREAD:  irecv -> READ_REQ -> remote isend -> complete"]

  SHPath --> AProg
  CHPath --> AProg

  AAgent -->|"6. checkXfer()"| ABackend
  ABackend -->|"flagcx_nixl_poll()"| ASB
  ASB -->|"done / in-prog"| ABackend

  %% =========================
  %% Notification
  %% =========================
  ABackend -->|"optional completion notif\nflagcx_nixl_send_notif()"| ASB
  ASB -->|"same-host: shm ctrl block"| BCtrl
  ASB -->|"cross-host: net ctrl plane"| BNet

  BSB -->|"flagcx_nixl_drain_notifs()"| BBackend
  BBackend -->|"getNotifs()"| BAgent

```

# 123

```mermaid
flowchart LR
  %% =========================
  %% Agent A
  %% =========================
  subgraph A["Agent A"]
    direction TB

    subgraph A1["NIXL 侧改动"]
      AAgent["nixlAgent"]
      APlugin["libplugin_flagcx.so\nflagcx_plugin.cpp"]
      ABackend["nixlFlagcxEngine\nflagcx_backend.h/.cpp\nsupportsRemote=true\nsupportsLocal=false\nsupportsNotif=true"]
      AMD["nixlFlagcxBackendMD\nLOCAL_REG / REMOTE_IMPORTED"]
      AReq["nixlFlagcxReqH\nPREPARED / POSTED / COMPLETED"]
    end

    subgraph A2["FlagCX 侧改动"]
      ASB["flagcx_nixl_engine\nflagcx_nixl_engine.h/.cc"]
      AConn["peer cache / conn state"]
      AMem["local_mem / remote_mem"]
      AProg["accept_thread\nprogress_thread"]
      ACtrl["same-host ctrl block\nshm ring / notif / error / close"]
      ADev["deviceAdaptor\nipcMemHandleCreate/Open/Close\n deviceMemcpy"]
      ANet["netAdaptor\nctrl/data comm\nisend/irecv/test"]
    end

    AAgent --> APlugin --> ABackend --> ASB
    ABackend --> AMD
    ABackend --> AReq
    ASB --> AConn
    ASB --> AMem
    ASB --> AProg
    ASB --> ACtrl
    ASB --> ADev
    ASB --> ANet
  end

  %% =========================
  %% Agent B
  %% =========================
  subgraph B["Agent B"]
    direction TB

    subgraph B1["NIXL 侧改动"]
      BAgent["nixlAgent"]
      BPlugin["libplugin_flagcx.so"]
      BBackend["nixlFlagcxEngine"]
      BMD["nixlFlagcxBackendMD"]
      BReq["nixlFlagcxReqH"]
    end

    subgraph B2["FlagCX 侧改动"]
      BSB["flagcx_nixl_engine"]
      BConn["peer cache / conn state"]
      BMem["local_mem / remote_mem"]
      BProg["accept_thread\nprogress_thread"]
      BCtrl["same-host ctrl block"]
      BDev["deviceAdaptor"]
      BNet["netAdaptor"]
    end

    BAgent --> BPlugin --> BBackend --> BSB
    BBackend --> BMD
    BBackend --> BReq
    BSB --> BConn
    BSB --> BMem
    BSB --> BProg
    BSB --> BCtrl
    BSB --> BDev
    BSB --> BNet
  end

  %% =========================
  %% Metadata / lifecycle
  %% =========================
  ABackend -. "1. getConnInfo()" .-> ASB
  ASB -. "connInfo blob\nversion/agent/host_hash/device_id/\nctrl_desc/net listen handle" .-> BBackend
  BBackend -. "2. loadRemoteConnInfo()" .-> BSB

  BBackend -. "registerMem()\nflagcx_nixl_reg_mem()" .-> BSB
  BSB -. "public md blob\nmem_token/base/len/type/\noptional ipc_handle" .-> ABackend
  ABackend -. "loadRemoteMD()\nflagcx_nixl_import_mem()" .-> ASB

  AAgent -->|"3. connect(remote_agent)"| ABackend
  ABackend -->|"flagcx_nixl_connect()"| ASB
  ASB --> T{"Topology?"}

  T -->|"same-host"| SH["导入 peer ctrl block\nremote md 打开 IPC handle\nremote_mem.ipc_mapped_ptr ready"]
  T -->|"cross-host"| CH["建立 ctrl_send/recv_comm\n建立 data_send/recv_comm"]

  %% =========================
  %% Transfer path
  %% =========================
  AAgent -->|"4. prepXfer()"| ABackend
  ABackend -->|"组装 iov\nlocal_offset / remote_offset"| AReq
  AAgent -->|"5. postXfer()"| ABackend
  ABackend -->|"flagcx_nixl_submit(op, iovs)"| ASB

  SH --> SHPath["same-host data path\nWRITE: memcpy(remote_ptr+off, local_ptr+off)\nREAD:  memcpy(local_ptr+off, remote_ptr+off)"]
  CH --> CHPath["cross-host data path\nWRITE: WRITE_REQ -> READY -> isend -> DONE\nREAD:  irecv -> READ_REQ -> remote isend -> complete"]

  SHPath --> AProg
  CHPath --> AProg

  AAgent -->|"6. checkXfer()"| ABackend
  ABackend -->|"flagcx_nixl_poll()"| ASB
  ASB -->|"done / in-prog"| ABackend

  %% =========================
  %% Notification
  %% =========================
  ABackend -->|"optional completion notif\nflagcx_nixl_send_notif()"| ASB
  ASB -->|"same-host: shm ctrl block"| BCtrl
  ASB -->|"cross-host: net ctrl plane"| BNet

  BSB -->|"flagcx_nixl_drain_notifs()"| BBackend
  BBackend -->|"getNotifs()"| BAgent

```

# Excalidraw Data

## Text Elements
NIXL ^MX4YlBat

Flagcx ^I4d8ilv0

nixlAgent::createBackend() ^Od5QRKPr

1. plugin manager ^4hsbFqcI

nixlFlagcxEngine ^ZgftYQXX

flagcx_nixl_engine_create(),都去flagcxGetUniqueId，用的时候都用 rank0
params 变为长期 flagcx_nixl_engine* ^htsWCAuu

nixlBackendInitParams ^49oKfPfp

2. getConnInfo ^tvOMElXp

flagcx_nixl_get_conn_info()
序列化 uniqueId+host+dev，变成 blob 格式返回
 ^KwiemVQI

3.getSupportedMems() ^lkdfiPd1

返回支持 VRAM ^rOCyY2CK

nixlFlagcxEngine::loadRemoteConnInfo
这里框架会帮你把远端的 blob 送过来，见
文档 0内的 ^BY1DATJf

flagcx_nixl_load_remote_conn_info()，把
对端的 blob反序列化给自己使用 ^0aA5Kyys

blob+remoteAgent(i) ^95DO7Io0

也叫 metadata ^nFed1RWu

self ^ulcRat2u

nFE::connect ^LeXIUc1L

flagcx_nixl_connect()这个函数只调用 
flagcxCommInitRank(comm, 2, uid, rank) ^mKNbvWzt

nFE::prepXferDlist
 ^d9WL86wM

self ^MJIs6KKU

用nixlFlagcxBackendMD*
来构造nixl_meta_dlist_t ^3mBXxtgP

self ^yJGhQSrA

生成一个nixlFlagcxReqH ^3uVkvqrF

    nFE::postXferReq()
返回一个flagcx_nixl_req_t* ^iwzb5Hx4

flagcx_nixl_submit(engine, conn, op, iovs, niov, &req) ^w1NAdcCs

NIXL_IN_PROG ^xz8Lafjh

nFE::checkXfer()
如果拿到 done 就补发
一条 notify ^CketwaXT

flagcx_nixl_poll(engine, req, &done) ^gq18E9Ou

notify ^nKpAkxwv

flagcx_nixl_send_notify ^D27tW7aL

flagcx_nixl_req_free ^3bRo4FGD

done? ^hzSsD4pl

init backend ^LLxxZHE9

NIXL_WRITE ^Y9kiGwyw

NIXL_READ ^M9qo3AfV

if reg && IBRC && Put ^zsf19Vah

Put ^trYeTJnQ

flagcxRecv ^sDPOocb1

flagcxSend ^KQ0Z5mTA

transfer ^OdqXjr70

nFE::loadRemoteMD()
only put need to remote_offset ^ctrFr5XM

metadataB ^oG9wo4am

register ^oHCyCl7z

because:
put need windows register ^If3LGC7w

one_sided？ ^vkBKxxVc

nFE::registerMem()
要求返回一个metadataP ^9uphxK1e

nixlLocalSection::addDescList() ^T3tirPwY

对 desc 注册本地 buffer ^gV3QUkwc

flagcx_nixl_reg_mem()去调用flagcxCommRegister ^9JV6eLz8

if put ^iOgGvn2G

self ^z13spuUg

nFE::getPublicData() ^dkoYWKMi

self（现在本地就有了 addr, lem, devId, metadataP, metadataB） ^A2tFS5P5

from metadataP
to metadataB ^Yp404RPz

listener 线程 ^ezpYF52p

%%
## Drawing
```compressed-json
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
```
%%