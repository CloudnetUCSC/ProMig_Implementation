#!/bin/bash

# Configuration - Set these variables before running
# For security, use environment variables: export SOURCE_SERVER=, export DEST_SERVER=, export VM_PASSWORD=
SOURCE_SERVER="${SOURCE_SERVER}"
DEST_SERVER="${DEST_SERVER}"
VM_PASSWORD="${VM_PASSWORD:-}" # Set via environment variable for security
SOURCE_VM="${SOURCE_VM:-}"
SSH_USER="${SSH_USER:-root}"

# Script parameters
ethernet_capacity_kbps=125000
num_levels=2  # Low, Moderate, High
num_states=$((num_levels ** 4))  # 3^4 states for 4 metrics
no_of_states_ahead=5
ITERATIONS=1
LOG_FILE="migration_log.txt"

thresholds=(0.40)

# Define workload configurations
workloads=( 
  "workload1 workload2 workload3 workload4"
   "workload1 workload5 workload3 workload5"
   "workload3 workload1 workload2 workload5"
   "workload3 workload2 workload1 workload5"
   "workload1 workload2 workload5 workload3"
   "workload1 workload3 workload5 workload3"
)

# Migration script paths (configure as needed)
PRE_COPY_DST_SCRIPT="${PRE_COPY_DST_SCRIPT:-/opt/migration-scripts/pre-copy-dst.sh}"
POST_COPY_DST_SCRIPT="${POST_COPY_DST_SCRIPT:-/opt/migration-scripts/post-copy-dst.sh}"
PRE_COPY_SRC_SCRIPT="${PRE_COPY_SRC_SCRIPT:-/opt/migration-scripts/pre-copy-src.sh}"
POST_COPY_SRC_SCRIPT="${POST_COPY_SRC_SCRIPT:-/opt/migration-scripts/post-copy-src.sh}"
HYBRID_SRC_SCRIPT="${HYBRID_SRC_SCRIPT:-/opt/migration-scripts/hybrid-src.sh}"
MIGRATION_STATUS_SCRIPT="${MIGRATION_STATUS_SCRIPT:-./migration-status.sh}"

# VM startup script paths
SOURCE_VM_START_SCRIPT="${SOURCE_VM_START_SCRIPT:-/opt/vm-scripts/start-source-vm.sh}"
DEST_VM_START_SCRIPT="${DEST_VM_START_SCRIPT:-/opt/vm-scripts/start-dest-vm.sh}"
WORKLOAD_SCRIPT="${WORKLOAD_SCRIPT:-/opt/workloads/run-workload.sh}"
MATRIX_SCRIPT="${MATRIX_SCRIPT:-./start-matrix.py}"

# Function to terminate VM instances on both source and destination servers
terminate_vms() {
  if [[ -z "$VM_PASSWORD" ]]; then
    echo "Error: VM_PASSWORD not set. Set via environment variable."
    return 1
  fi
  
  sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$DEST_SERVER" "pkill qemu" 2>/dev/null
  echo ">>> Terminated Destination VMs"
  sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$SOURCE_SERVER" "pkill qemu" 2>/dev/null
  echo ">>> Terminated Source VMs"
}

get_migration_details() {
	MIGRATION=""
	COUNT=0
	MAX_RETRIES=100
	RETRY_DELAY=80

	while [[ $MIGRATION != *"completed"* ]];
	do
		if [[ $COUNT -eq $MAX_RETRIES ]]
		then 
			echo ">>> Migration Failure"
			log ">>> Migration Failure"
			
			if [[ -z "$VM_PASSWORD" ]]; then
				echo "Error: Cannot cleanup - VM_PASSWORD not set"
				exit 255
			fi
			
			# Cleanup on both servers
			for SERVER in "$SOURCE_SERVER" "$DEST_SERVER"; do
				sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$SERVER" "pkill qemu" 2>/dev/null
				sleep 10
			done
			exit 255
		fi
		sleep $RETRY_DELAY
		echo ">>> Checking for Migration Status"
    MIGRATION=$(bash "$MIGRATION_STATUS_SCRIPT" 2>/dev/null)
    echo "Migration status : $MIGRATION" >> "$LOG_FILE"
		((COUNT++))
	done
	echo ">>> Migration Completed"
	terminate_vms
}

postcopy_migration() {
  if [[ -z "$VM_PASSWORD" ]]; then
    echo "Error: VM_PASSWORD not set. Set via environment variable."
    return 1
  fi
  
  echo "Post Copy Migration is required"
  sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$DEST_SERVER" "bash $POST_COPY_DST_SCRIPT"
  sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$SOURCE_SERVER" "bash $POST_COPY_SRC_SCRIPT"
  get_migration_details
  sleep 20
  terminate_vms
}

precopy_migration(){
  if [[ -z "$VM_PASSWORD" ]]; then
    echo "Error: VM_PASSWORD not set. Set via environment variable."
    return 1
  fi
  
  echo "Pre Copy Migration is required"
  sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$SOURCE_SERVER" "bash $PRE_COPY_SRC_SCRIPT"
  get_migration_details
  sleep 20
  terminate_vms
}

hybrid_migration(){
  if [[ -z "$VM_PASSWORD" ]]; then
    echo "Error: VM_PASSWORD not set. Set via environment variable."
    return 1
  fi
  
  echo "Hybrid Migration is required"
  sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$DEST_SERVER" "bash $POST_COPY_DST_SCRIPT"
  sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$SOURCE_SERVER" "bash $HYBRID_SRC_SCRIPT"
  get_migration_details
  sleep 20
  terminate_vms
}

# Function to start monitoring VM state and update the matrices
monitor_vm_state() {
    local threshold_value=$1
    result=$(python3 "$MATRIX_SCRIPT") #Call RT_FSP.py to get the migration decision

    # Now, you can process the output
    echo "Result from Python: $result"

    # Split the result into variables if needed
    migration_decision=$(echo $result | cut -d' ' -f1)
    elapsed_time=$(echo $result | cut -d' ' -f2)

    echo "Migration Decision: $migration_decision" >> "$LOG_FILE"
    echo "Elapsed Time: $elapsed_time" >> "$LOG_FILE"

    if [[ $migration_decision == "Pre-Copy" ]]
    then
      precopy_migration
    elif [[ $migration_decision == "Post-Copy" ]]
    then
      postcopy_migration
    elif [[ $migration_decision == "Hybrid" ]]
    then
      hybrid_migration
    else
      echo "Migration Decision is not valid"
      terminate_vms
    fi
}

# Validation before running main script
if [[ -z "$SOURCE_SERVER" ]] || [[ -z "$DEST_SERVER" ]]; then
  echo "Error: SOURCE_SERVER and DEST_SERVER must be configured"
  exit 1
fi

if [[ -z "$VM_PASSWORD" ]]; then
  echo "Error: VM_PASSWORD environment variable not set"
  echo "Usage: export SOURCE_SERVER=<host> DEST_SERVER=<host> VM_PASSWORD=<pass> && bash $0"
  exit 1
fi

# Main script flow
for threshold in "${thresholds[@]}"
do
  for k in "${workloads[@]}"
  do
    workload_name=$k
    for b in $(seq 1 "$ITERATIONS")
    do
      #write the iteration details to the log file
      echo "Starting Synthetic workload for configuration: $workload_name round: $b" >> "$LOG_FILE"

    # Start the source VM
      echo "Starting the source VM..."
      sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$SOURCE_SERVER" \
      "bash $SOURCE_VM_START_SCRIPT" &
      sleep 30  

      # Start the destination VM
      echo "Starting the destination VM..."
      sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$DEST_SERVER" \
      "bash $DEST_VM_START_SCRIPT" &
      sleep 30  

      # Run workload on the source VM before migration
      echo "Running Synthetic Workload on the source VM..."
      sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "$SSH_USER"@"$SOURCE_VM" "
        bash $WORKLOAD_SCRIPT $workload_name" &

      monitor_vm_state "$threshold"

      sleep 10  # Monitor for 10 seconds

      echo "Monitoring completed...."

    done
    echo "Completed Synthetic Workload for configuration: $workload_name"
    echo "" >> "$LOG_FILE"
    sleep 20
  done
done

