# Fault Tolerance

VCCL’s fault-tolerance mechanism ensures that, in the event of NIC down or switch failures, distributed training can be recovered and continue within a single iteration, significantly improving the reliability and availability of large-scale clusters.

## Overview

### Fault-tolerance Capabilities
- **Failure Detection**: Automatically detects node and link failures.
- **Automatic Recovery**: Transparent failure recovery mechanisms.
- **Zero Downtime**: In-place recovery within a single iteration.
- **High Compatibility**: Highly compatible with traditional solutions.

### Supported Failure Types
| Failure Type | Recovery Strategy | Recovery Time |
|----------|----------|----------|
| **NIC down** | Fault tolerance | Within 1 iteration |
| **Switch failure** | Fault tolerance | Within 1 iteration |
| **NIC flap** | Avoid excessive re-attachment | Handled by hardware retransmission mechanisms|
| **GPU failure** | Node isolation | Checkpoint-based recovery |


## Configuration

### Basic Enablement
```bash
# Enable fault-tolerance feature (disabled by default)
export NCCL_ENABLE_FAULT_TOLERANCE=<0, 1>, default is 0 (disabled).

# NIC configuration must be specified
export NCCL_IB_HCA=="mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_7:1" according to runtime environment.
```


### Advanced Configuration
```bash
# Set retry count (default 7)
export NCCL_IB_RETRY_COUNT=7

# Set timeout in seconds (default 18)
export NCCL_IB_TIMEOUT=18
```



---

!!! warning "NIC configuration requirement"
    The fault-tolerance feature requires the NCCL_IB_HCA environment variable to be specified; otherwise it will not function correctly.

!!! info "Advanced configuration"
    Setting advanced parameters beyond reasonable ranges may affect behavior.
