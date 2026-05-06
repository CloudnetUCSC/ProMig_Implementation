# VM Migration Orchestration System

A comprehensive suite of tools for intelligent VM migration with adaptive migration strategy selection based on future workload predictions.

## Overview

This system uses a **Migration_Controller** to handle the migratiion process and a **RT_FSP (Resource Tracker & Future State Predictor)** - a Markov chain-based decision engine - to intelligently select between three VM migration strategies:

- **Pre-Copy**: Copy memory before stopping the VM 
- **Post-Copy**: Pause VM, migrate memory, then resume 
- **Hybrid**: Combination approach 

**Core Flow:**
1. **Start Source VM** → Start Destination VM
2. **RT_FSP monitors** VM metrics (CPU, memory, network) in real-time
3. **RT_FSP predicts** future system behavior using Markov chain
4. **RT_FSP decides** optimal migration strategy
5. **Execute migration** using the chosen strategy
6. **Cleanup** and prepare for next iteration

## System Flow

┌─────────────────────────────────────────────────────────────────┐
│         PHASE 1: VM STARTUP                                     │
│  startSource.sh              startDestination.sh                │
│  (Start Source VM)           (Start Destination VM)             │
└──────────────┬───────────────────────────────────┬──────────────┘
               │                                   │
               └────────────────┬──────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────┐
│  PHASE 2: RESOURCE TRACKING & FUTURE STATE PREDICTION            │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ Monitor Real-Time Metrics                                │    │
│  │ ├─ CPU Usage         ├─ Memory Usage                     │    │
│  │ └─ Network I/O       └─ Classify: Low/High               │    │
│  └──────────────────────────────────────────────────────────┘    │
│                          ↓                                       │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ Update Markov Chain & Predict Future Behavior            │    │
│  │ ├─ Update state transition probabilities                 │    │
│  │ ├─ Predict next 15 states                                │    │
│  │ └─ Analyze trend for optimal strategy                    │    │
│  └──────────────────────────────────────────────────────────┘    │
└───────────────────────────────┬──────────────────────────────────┘
                                │
               ┌────────────────┴────────────────┐
               │ RT_FSP Decision Output          │
               │ (Migration Strategy + Time)     │
               ↓                                 ↓
┌────────────────────────┐      ┌──────────────────────────────┐
│   PRE-COPY             │      │     POST-COPY                │
│   (Stable workload)    │      │     (High workload)          │
│   precopy-vm-migrate   │      │     postcopy-vm-migrate      │
└────────────────────────┘      └──────────────────────────────┘
               │                                 │
               └────────────────┬────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  PHASE 3: MIGRATION EXECUTION                                   │
│           Migration_Controller executes chosen strategy         │
│           ├─ Transfer VM memory & state                         │
│           ├─ Monitor progress                                   │
│           └─ Complete migration                                 │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│  PHASE 4: CLEANUP & LOGGING                                     │
│  ├─ Stop QEMU processes                                         │
│  ├─ Log performance metrics                                     │
│  └─ System ready for next iteration                             │
└─────────────────────────────────────────────────────────────────┘

## Prerequisites

### System Requirements
- Linux with KVM support
- QEMU installed (`qemu-system-x86_64`)
- SSH access between servers
- `sshpass` for password-based SSH
- `socat` for QMP communication
- `ifstat` for network monitoring
- `mpstat` for CPU monitoring
- Python 3 with `numpy` and `paramiko`

### Setup
```bash
# Install dependencies (Ubuntu/Debian)
sudo apt-get install qemu-system-x86_64 sshpass socat sysstat python3-pip
pip3 install numpy paramiko

# Create VM image directories
sudo mkdir -p /opt/vm-images
sudo mkdir -p /opt/vm-scripts
sudo mkdir -p /opt/migration-scripts
sudo mkdir -p /opt/workloads
```

## Configuration

All scripts use environment variables for configuration. Set them before running:

```bash
# Essential Configuration
export SOURCE_SERVER="source-host-ip"
export DEST_SERVER="destination-host-ip"
export SOURCE_VM="source-vm-ip"
export VM_PASSWORD="your-ssh-password"

# Optional Configuration
export SSH_USER="root"                           # SSH user (default: root)
export NETWORK_INTERFACE="eth0"                  # Network interface (default: eth0)
export MIGRATION_PORT="4444"                     # Migration port (default: 4444)
export VM_IMAGE_DIR="/opt/vm-images"             # VM image directory
export QMP_SOCKET_DIR="/tmp"                     # QMP socket directory
export LOG_FILE="migration_analysis.log"         # Log file path

# Script Paths
export SOURCE_VM_START_SCRIPT="/opt/vm-scripts/start-source-vm.sh"
export DEST_VM_START_SCRIPT="/opt/vm-scripts/start-dest-vm.sh"
export PRE_COPY_SRC_SCRIPT="/opt/migration-scripts/precopy-vm-migrate.sh"
export POST_COPY_SRC_SCRIPT="/opt/migration-scripts/postcopy-vm-migrate.sh"
export WORKLOAD_SCRIPT="/opt/workloads/run-workload.sh"
export MATRIX_SCRIPT="./twolevels.py"           # RT_FSP: Resource Tracker & Future State Predictor
export MIGRATION_STATUS_SCRIPT="./migration-status.sh"
```

## Execution Flow Details

### Phase 1: VM Startup
```
Migration_Controller.sh:
  ├─ Start Source VM
  │  └─ startSource.sh $VM_NAME tap0 $MEMORY $VNC
  │     ├─ Create tap device
  │     ├─ Start QEMU with KVM
  │     └─ Enable QMP socket
  │
  └─ Start Destination VM
     └─ startDestination.sh $VM_NAME tap1 $MEMORY
        ├─ Create tap device
        ├─ Start QEMU with KVM
        ├─ Enable QMP socket
        └─ Listen for migration: -incoming tcp:0:4444
```

### Phase 2: Resource Tracking & Prediction (RT_FSP)
```
twolevels.py (RT_FSP) execution:
  
  1. Collect Metrics (Asynchronously):
     ├─ CPU Usage:      mpstat 1 1
     ├─ Memory Usage:   free command
     └─ Network I/O:    ifstat -i eth0 1 1
  
  2. Classify Current State (16 possible states):
     ├─ CPU level:       (0=Low, 1=High)
     ├─ Memory level:    (0=Low, 1=High)
     ├─ Incoming level:  (0=Low, 1=High)
     ├─ Outgoing level:  (0=Low, 1=High)
     └─ state_index = cpu*8 + memory*4 + incoming*2 + outgoing
  
  3. Update Markov Chain:
     ├─ count_matrix[prev_state][current_state] += 1
     └─ Recalculate probability_matrix from transitions
  
  4. Predict Future Behavior:
     ├─ future_matrix = probability_matrix^15
     ├─ Predict dominant state 15 steps ahead
     └─ Analyze memory/network trend
  
  5. Make Migration Decision:
     ├─ If current/predicted memory is HIGH
     │  └─ Decision: "Post-Copy" (minimize downtime)
     ├─ Elif current network is HIGH
     │  └─ Decision: "Post-Copy" (avoid network load)
     ├─ Elif memory predicted to rise
     │  └─ Decision: "Post-Copy"
     └─ Else
        └─ Decision: "Pre-Copy" or "Hybrid"
```

### Phase 3: Migration Execution
```
Based on RT_FSP Decision:

If "Pre-Copy":
  precopy-vm-migrate.sh
  ├─ Copy VM memory pages before stopping
  ├─ Enable XBZRLE optimization if needed
  ├─ Iterative copy dirty pages
  └─ Good for: Stable workloads with low memory churn

If "Post-Copy":
  postcopy-vm-migrate.sh
  ├─ Pause VM quickly on source
  ├─ Transfer VM state to destination
  ├─ Destination resumes immediately
  ├─ Fetch missing pages on-demand
  └─ Good for: High memory churn workloads

If "Hybrid":
  Both strategies coordinated
  ├─ Start with pre-copy for stability
  ├─ Switch to post-copy for efficiency
  └─ Minimize total migration time
```

### Phase 4: Monitoring & Cleanup
```
Migration_Controller.sh finalizes:
  ├─ Monitor migration status
  │  └─ Poll up to 100 times, 80 seconds apart
  ├─ Verify migration completion
  ├─ Log performance metrics and decisions
  └─ Cleanup:
     ├─ Terminate source QEMU
     ├─ Terminate destination QEMU
     └─ System ready for next iteration
```

## State Definition

The system uses a 2-level classification for 4 metrics:
- **CPU Usage**: Level 0 (Low < 40%), Level 1 (High ≥ 40%)
- **Memory Usage**: Level 0 (Low < 40%), Level 1 (High ≥ 40%)
- **Network Incoming**: Level 0 (Low), Level 1 (High)
- **Network Outgoing**: Level 0 (Low), Level 1 (High)

**State Index Formula:**
```
state_index = cpu_level × 8 + memory_level × 4 + incoming_level × 2 + outgoing_level
```

This creates 16 possible states (0-15).

For issues or questions, please refer to:
- QEMU Documentation: https://www.qemu.org/documentation/
- KVM Documentation: https://www.linux-kvm.org/
- SSH/Paramiko: https://www.paramiko.org/