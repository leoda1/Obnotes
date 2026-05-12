##  0. 前言

```shell title="b300 topo"
root@node001:/infrawaves/liuda# nvidia-smi topo -m
        GPU0    GPU1    GPU2    GPU3    GPU4    GPU5    GPU6    GPU7    NIC0    NIC1    NIC2    NIC3    NIC4    NIC5    NIC6    NIC7    NIC8    NIC9    NIC10   CPU Affinity    NUMA Affinity   GPU NUMA ID
GPU0     X      NV18    NV18    NV18    NV18    NV18    NV18    NV18    PXB     NODE    SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     NODE    0-31,128-159    0               N/A
GPU1    NV18     X      NV18    NV18    NV18    NV18    NV18    NV18    NODE    PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     NODE    0-31,128-159    0               N/A
GPU2    NV18    NV18     X      NV18    NV18    NV18    NV18    NV18    SYS     SYS     PXB     NODE    SYS     SYS     SYS     SYS     SYS     SYS     SYS     32-63,160-191   1               N/A
GPU3    NV18    NV18    NV18     X      NV18    NV18    NV18    NV18    SYS     SYS     NODE    PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     32-63,160-191   1               N/A
GPU4    NV18    NV18    NV18    NV18     X      NV18    NV18    NV18    SYS     SYS     SYS     SYS     PXB     NODE    SYS     SYS     NODE    NODE    SYS     64-95,192-223   2               N/A
GPU5    NV18    NV18    NV18    NV18    NV18     X      NV18    NV18    SYS     SYS     SYS     SYS     NODE    PXB     SYS     SYS     NODE    NODE    SYS     64-95,192-223   2               N/A
GPU6    NV18    NV18    NV18    NV18    NV18    NV18     X      NV18    SYS     SYS     SYS     SYS     SYS     SYS     PXB     NODE    SYS     SYS     SYS     96-127,224-255  3               N/A
GPU7    NV18    NV18    NV18    NV18    NV18    NV18    NV18     X      SYS     SYS     SYS     SYS     SYS     SYS     NODE    PXB     SYS     SYS     SYS     96-127,224-255  3               N/A
NIC0    PXB     NODE    SYS     SYS     SYS     SYS     SYS     SYS      X      NODE    SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     NODE
NIC1    NODE    PXB     SYS     SYS     SYS     SYS     SYS     SYS     NODE     X      SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     NODE
NIC2    SYS     SYS     PXB     NODE    SYS     SYS     SYS     SYS     SYS     SYS      X      NODE    SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC3    SYS     SYS     NODE    PXB     SYS     SYS     SYS     SYS     SYS     SYS     NODE     X      SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC4    SYS     SYS     SYS     SYS     PXB     NODE    SYS     SYS     SYS     SYS     SYS     SYS      X      NODE    SYS     SYS     NODE    NODE    SYS
NIC5    SYS     SYS     SYS     SYS     NODE    PXB     SYS     SYS     SYS     SYS     SYS     SYS     NODE     X      SYS     SYS     NODE    NODE    SYS
NIC6    SYS     SYS     SYS     SYS     SYS     SYS     PXB     NODE    SYS     SYS     SYS     SYS     SYS     SYS      X      NODE    SYS     SYS     SYS
NIC7    SYS     SYS     SYS     SYS     SYS     SYS     NODE    PXB     SYS     SYS     SYS     SYS     SYS     SYS     NODE     X      SYS     SYS     SYS
NIC8    SYS     SYS     SYS     SYS     NODE    NODE    SYS     SYS     SYS     SYS     SYS     SYS     NODE    NODE    SYS     SYS      X      PIX     SYS
NIC9    SYS     SYS     SYS     SYS     NODE    NODE    SYS     SYS     SYS     SYS     SYS     SYS     NODE    NODE    SYS     SYS     PIX      X      SYS
NIC10   NODE    NODE    SYS     SYS     SYS     SYS     SYS     SYS     NODE    NODE    SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS      X 
```

```shell title="物理 topo"
╔══════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                         4-Socket Server                                          ║
╠══════════════════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                                 ║
║  NUMA 0 (CPU0, core 0-31/128-159)                    NUMA 1 (CPU1, core 32-63/160-191)          ║
║  ┌──────────────────────────────────────┐            ┌───────────────────────────────┐          ║
║  │            Root Complex 0            │            │       Root Complex 1          │          ║
║  │  ┌─────────┐ ┌─────────┐             │            │  ┌─────────┐ ┌─────────┐      │          ║
║  │  │Switch #0│ │Switch #1│  NIC10      │            │  │Switch #2│ │Switch #3│      │          ║
║  │  │┌──┐┌──┐ │ │┌──┐┌──┐ │  (独立)      │            │  │┌──┐┌──┐│ │┌──┐┌──┐│        │          ║
║  │  ││G0││N0│ │ ││G1││N1│ │             │            │  ││G2││N2││ ││G3││N3││        │          ║
║  │  │└──┘└──┘ │ │└──┘└──┘ │             │            │  │└──┘└──┘│ │└──┘└──┘│        │          ║
║  │  └─────────┘ └─────────┘             │            │  └─────────┘ └─────────┘      │          ║
║  └──────────────────────────────────────┘            └───────────────────────────────┘          ║
║                                                                                                 ║
║  NUMA 2 (CPU2, core 64-95/192-223)                    NUMA 3 (CPU3, core 96-127/224-255)        ║
║  ┌──────────────────────────────────────────┐        ┌───────────────────────────────┐          ║
║  │            Root Complex 2                │        │       Root Complex 3          │          ║
║  │  ┌─────────┐ ┌─────────┐ ┌───────────┐   │        │  ┌─────────┐ ┌─────────┐      │          ║
║  │  │Switch #4│ │Switch #5│ │Switch #8  │   │        │  │Switch #6│ │Switch #7│      │          ║
║  │  │┌──┐┌──┐ │ │┌──┐┌──┐│ │┌───┐┌───┐  │   │        │  │┌──┐┌──┐│ │┌──┐┌──┐  │      │          ║
║  │  ││G4││N4│ │ ││G5││N5││ ││N8 ││N9 │  │   │        │  ││G6││N6││ ││G7││N7│  │      │          ║
║  │  │└──┘└──┘ │ │└──┘└──┘│ │└───┘└───┘  │   │        │  │└──┘└──┘│ │└──┘└──┘  │      │          ║
║  │  └─────────┘ └─────────┘ └───────────┘   │        │  └─────────┘ └─────────┘      │          ║
║  └──────────────────────────────────────────┘        └───────────────────────────────┘          ║
║                                                                                                 ║
║                        GPU 之间全部通过 NVLink (NV18) 全互联                                       ║
╚══════════════════════════════════════════════════════════════════════════════════════════════════╝
```