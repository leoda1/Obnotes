# Flow Telemetry

VCCL Flow Telemetry provides microsecond-level GPU-to-GPU point-to-point traffic measurement, helping users gain deep insights into distributed training communication patterns, identify performance bottlenecks, and perform precise optimizations.

## Feature Overview

- **Real-time monitoring**: provides microsecond-level GPU-to-GPU point-to-point traffic measurement
- **Congestion awareness**: inference of network congestion conditions
- **Developer assistance**: aids in R&D tuning and optimization


## Config

### Basic usage
```bash
# Enable telemetry
export NCCL_TELEMETRY_ENABLE=1

# Set data window size (default: 50)
export TELEMETRY_WINDOWSIZE=100

# Set log output path
export NCCL_TELEMETRY_LOG_PATH=/tmp/vccl_telemetry
```

## Changelog
2026.1.8 [https://github.com/sii-research/VCCL/pull/21](https://github.com/sii-research/VCCL/pull/21)

This PR introduces a new environment variable NCCL_TELEMETRY_OBSERVE to differentiate between troubleshooting mode (value 0, default) and monitoring mode (value 1). The primary goal is to make the global timer log lock-free to prevent performance degradation in the NCCL proxy critical path.
