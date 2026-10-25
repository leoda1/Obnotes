# Topology-Aware Traffic Load Balancing


## Overview

### How It Works
VCCL analyzes the cluster’s network topology to automatically identify the optimal communication paths, and dynamically adjusts routing strategies at runtime to avoid congestion and hotspots.


#### 1. Hardware Acceleration
- Fully leverage hardware-native mechanisms. For example, the widely used GDR (GPUDirect) technology accelerates data transfers between GPU memory and RDMA NICs. With GDR enabled, data can be sent directly to the RDMA NIC without passing through host memory.
- Utilize PXN technology to switch data paths within a server node. PXN redirects traffic onto the target GPU’s communication rail locally, reducing cross-rail transmissions in the network and thus lowering latency.


#### 2. Traffic Load Balancing
- Multi-rail optimization
- Ensure that traffic within a BLOCK is not routed through the Layer-3 Spine switches

## Configuration

### Default Behavior
Topology-aware load balancing is enabled by default with no additional configuration required:

```bash
# Enabled by default, automatically selects the optimal strategy
# No environment variables need to be set
```
