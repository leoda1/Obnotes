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

nixlAgent::createBackend ^Od5QRKPr

1. plugin manager ^4hsbFqcI

nixlFlagcxEngine ^ZgftYQXX

flagcx_nixl_engine_create()
params 变为长期 flagcx_nixl_engine* ^htsWCAuu

nixlBackendInitParams ^49oKfPfp

2. getConnInfo ^tvOMElXp

flagcx_nixl_export_conn_info()
返回一个 connInfo，以 blob 给 nixl
 ^KwiemVQI

3.getSupportedMems() ^lkdfiPd1

返回支持 VRAM ^rOCyY2CK

nixlFlagcxEngine::loadRemoteConnInfo ^BY1DATJf

flagcx_nixl_import_conn_info()
对端导入 blob， ^0aA5Kyys

blob+remoteAgent(i) ^95DO7Io0

也叫 metadata ^nFed1RWu

nFE::registerMem()
拿到 blob 后生成 ，
nixlFlagcxBackendMD，
MD 会存在NIXL 的 metadataP ^y0sNiAA2

nixlLocalSection::addDescList() ^V3Q0qZBj

self ^ulcRat2u

对 desc 注册本地 buffer ^TLhMZOqY

flagcx_nixl_reg_mem(addr, len, mem_type, &local_mem)
用户 buffer----->flagcx_nixl_local_mem_t* ^cknVxI1f

flagcx_nixl_export_mem(local_mem, &blob)
flagcx_nixl_local_mem_t*---->blob ^aKIqFyfq

blob ^H5ppUe76

nFE::getPublicData()
 ^xOjRx2nz

self ^yUCkGDY1

from metadataP
to metadataB ^NM7kktUN

nFE::loadRemoteMD()
wrapper 生成远端 MD ^kJ3CeH1D

nixlFlagcxEngine::loadRemoteMD() ^nCpiC3mF

flagcx_nixl_import_mem(engine, remote_agent, input.metaInfo, blob_len, &remote_mem)
if sameNode, open Ipc; else parse metadataB from blob to flagcx_nixl_remote_mem_t ^q3QYLcjp

metadataB ^KLZqObZo

nFE::connect ^LeXIUc1L

机内：导入 shm struct
机间：用 connInfo 里面 handle 创建ctrl_send/recv_comm 和 data_send/recv_comm
flagcx_nixl_conn_t{topology=CROSS_HOST,.....} ^mKNbvWzt

nFE::prepXferDlist ^d9WL86wM

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

nFE::getNotifs()
get notif_list_t  ^HGRIVehM

flagcx_nixl_drain_notifs ^YwdBV0Hg

flagcx_nixl_req_free ^3bRo4FGD

done? ^hzSsD4pl

finish? ^sq35kDK7

flagcx_nixl_dereg_mem ^nX47fuL8

fail? ^BvnYPsCE

flagcx_nixl_free_remote_mem ^QzlWMwG0

fail/finish? ^LYvHoPPh

disconnect ^YQRtP2Cg

deviceMemcpy ^R9lZlg1A

netadaptor ^NRPjKOd0

ibrc:put/putSignal ^zCELRcLN

normal ^NWmYj1Kz

%%
## Drawing
```compressed-json
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
```
%%