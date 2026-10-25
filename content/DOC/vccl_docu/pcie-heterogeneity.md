# PCIe Heterogeneity and Smart RNIC Selection (SRS)

In current servers based on PCIe heterogeneous architectures (e.g., CPU, GPU, RNIC), we encounter network performance bottlenecks caused by topology differences. Manifestations include failed cross-device communication and imbalanced traffic across multi-NIC ports, resulting in RDMA performance falling short of expectations. To systematically address these issues, we designed corresponding optimization schemes for different hardware configurations.

## Feature Overview

### 
- **Heterogeneity support**: topology-aware device binding
- **Traffic balancing**: RDMA QP scheduling that balances across ports
- **Adaptivity**: heterogeneity-aware adaptive strategies



## Supported Heterogeneous Scenarios

| PCIe heterogeneity scenario | Solution |
|-----------|----------|
| One GPU, one RNIC, one port | Supported |
| One GPU, one RNIC, two ports | RDMA QPs use the two ports evenly |
| Two GPUs, two RNICs, two ports | Supported |
| Two GPUs, two RNICs, four ports | One GPU uses one RNIC; RDMA QPs evenly use all ports |

## Configuration

### Default behavior
SRS is enabled by default and automatically makes the optimal choice:

```bash
# Enabled by default — no extra configuration required
# VCCL will automatically discover and select the optimal RNIC
```


