#Resource Tracker and Future State Predictor
import paramiko
import time
import asyncio
import numpy as np
import sys
import logging
import os

# Configuration from environment variables or defaults
SSH_USER = os.getenv('SSH_USER', 'root')
VM_PASSWORD = os.getenv('VM_PASSWORD', '')
SOURCE_VM = os.getenv('SOURCE_VM', 'localhost')
SOURCE_SERVER = os.getenv('SOURCE_SERVER', 'localhost')
DEST_SERVER = os.getenv('DEST_SERVER', 'localhost')

# Script paths - configure as needed
START_VM_SCRIPT = os.getenv('START_VM_SCRIPT', '/opt/vm-scripts/start-vm.sh')
NETWORK_INTERFACE = os.getenv('NETWORK_INTERFACE', 'eth0')

# Performance parameters
ethernet_capacity_kbps = 125000
num_levels = 2  # Low, High
num_states = num_levels**4
no_of_states_ahead = 15
TRAINING_DURATION = 67  # seconds
MONITOR_INTERVAL = 1  # seconds
THRESHOLD = 0.40

# Logging
LOG_FILE = os.getenv('LOG_FILE', 'migration_analysis.log')
logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format='%(message)s')

# Initialize the count matrix and probability matrix (number of states x number of states)
count_matrix = [[0 for _ in range(num_states)] for _ in range(num_states)]
probability_matrix = [[1 / num_states for _ in range(num_states)] for _ in range(num_states)]

def get_level(value):
    """Classify metric value into levels based on threshold."""
    if value < THRESHOLD:
        return 0
    else:
        return 1

def update_probability_matrix(previous_state_idx, count_matrix, num_states):
    """
    Update the probability matrix based on the count matrix.
    """
    transition_sum = sum(count_matrix[previous_state_idx])
    if transition_sum > 0:
        for i in range(num_states):
            probability_matrix[previous_state_idx][i] = count_matrix[previous_state_idx][i] / transition_sum

def predict_future_states(current_state_idx, no_of_states_ahead,num_states):
    """
    Predict the future states based on the current state and the probability matrix.
    """
    global count_matrix, probability_matrix
    #1 for the current state and 0 for the rest
    initial_state_vector = [0 for _ in range(num_states)]
    initial_state_vector[current_state_idx] = 1

    # Convert to numpy arrays
    probability_matrix = np.array(probability_matrix)
    initial_state_vector = np.array(initial_state_vector)

    # Calculate the state vector after `steps_ahead` steps
    future_transition_matrix = np.linalg.matrix_power(probability_matrix, no_of_states_ahead)
    predicted_state_vector = future_transition_matrix.dot(initial_state_vector)

    # Find the index of the maximum probability state
    max_state_index = np.argmax(predicted_state_vector)
    return max_state_index

def compute_steady_state(probability_matrix):
    """
    Compute the steady state of the Markov chain.
    """
    probability_matrix = np.array(probability_matrix)
    num_states = probability_matrix.shape[0]
    A = np.transpose(probability_matrix) - np.eye(num_states)
    A[-1] = np.ones(num_states)
    b = np.zeros(num_states)
    b[-1] = 1
    steady_state = np.linalg.lstsq(A, b, rcond=None)[0]
    return steady_state

def migration_decision(state_index, no_of_states_ahead,num_states):
    global count_matrix, probability_matrix
    migration_decision = "No migration"
    next_memory_level = 0   
    next_outgoing_level = 0
    start_time = time.time()

    #current state index to levels
    current_cpu_level = state_index // num_levels**3
    current_memory_level = (state_index // num_levels**2) % num_levels
    current_incoming_level = (state_index // num_levels) % num_levels
    current_outgoing_level = state_index % num_levels

    logging.info(f"Current cpu level: {current_cpu_level}, memory level: {current_memory_level}, incoming level: {current_incoming_level}, outgoing level: {current_outgoing_level}")

    next_states = []
    if(current_incoming_level ==1 or current_cpu_level ==1):
        logging.info(f"High Incoming or CPU Level")
        for i in range(no_of_states_ahead):
            next_states.append(predict_future_states(state_index, i+1,num_states))
            memory_level = (next_states[i] // num_levels**2) % num_levels
            outgoing_level = next_states[i] % num_levels
            cpu_level = next_states[i] // num_levels**3
            incoming_level = (next_states[i] // num_levels) % num_levels

            logging.info(f"Predicted:{i}")
            logging.info(f"CPU Level: {cpu_level}, Memory Level: {memory_level}, Incoming Level: {incoming_level}, Outgoing Level: {outgoing_level}")

            if(memory_level == 1):
                next_memory_level = 1
                break
            else:
                next_memory_level= memory_level 

    if current_memory_level == 1:
        migration_decision = "Post-Copy"
    elif current_outgoing_level == 1:
        migration_decision = "Post-Copy"
    elif current_incoming_level == 1:
        if next_memory_level == 1 :
            migration_decision = "Post-Copy"
        else:
            migration_decision = "Pre-Copy"
    else:
        if next_memory_level == 1 :
            migration_decision = "Post-Copy"
        else:
            migration_decision = "Hybrid"

    end_time = time.time()
    elapsed_time = end_time - start_time

    #time in milliseconds
    elapsed_time = elapsed_time * 1000

    sys.stdout.write(f"{migration_decision} {elapsed_time}")
    sys.exit(0) 

async def fetch_cpu_usage(ssh_client):
    stdin, stdout, stderr = ssh_client.exec_command("mpstat 1 1 | awk '/Average/ {print 100 - $NF}'")
    cpu_usage = stdout.read().decode("utf-8").strip()
    return float(cpu_usage) / 100

async def fetch_memory_usage(ssh_client):
    stdin, stdout, stderr = ssh_client.exec_command("free | awk '/^Mem:/ {print $3 / $2}'")
    used_memory = stdout.read().decode("utf-8").strip()
    return float(used_memory)

async def fetch_network_usage(ssh_client):
    cmd = f"ifstat -i {NETWORK_INTERFACE} 1 1 | awk 'NR==3 {{print $1, $2}}'"
    stdin, stdout, stderr = ssh_client.exec_command(cmd)
    network_usage = stdout.read().decode("utf-8").strip()
    incoming_network, outgoing_network = map(float, network_usage.split())
    in_net_usage = incoming_network / ethernet_capacity_kbps
    out_net_usage = outgoing_network / ethernet_capacity_kbps
    return in_net_usage, out_net_usage


async def run_iteration():
    # Validate environment
    if not VM_PASSWORD:
        logging.error('VM_PASSWORD environment variable not set')
        sys.exit(1)
    
    trainingtime_Start = time.time()
    prev_state_index = 0
    counter = 0

    # Setup SSH client
    ssh_client = paramiko.SSHClient()
    ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh_client.connect(SOURCE_VM, username=SSH_USER, password=VM_PASSWORD)

    while True:
        # Fetch CPU, memory, and network in parallel
        cpu_usage, used_memory, (incoming_network, outgoing_network) = await asyncio.gather(
            fetch_cpu_usage(ssh_client),
            fetch_memory_usage(ssh_client),
            fetch_network_usage(ssh_client)
        )

        # Determine levels for the current state
        cpu_level = get_level(cpu_usage)
        memory_level = get_level(used_memory)
        incoming_level = get_level(incoming_network)
        outgoing_level = get_level(outgoing_network)

        logging.info(f"CPU Level: {cpu_level}, Memory Level: {memory_level}, Incoming Level: {incoming_level}, Outgoing Level: {outgoing_level}")

        # State index calculation
        state_index = (
            cpu_level * num_levels**3
            + memory_level * num_levels**2
            + incoming_level * num_levels
            + outgoing_level
        )

        logging.info(f"State Index: {state_index}")

        if counter == 0:
            prev_state_index = state_index
        else:
            # Update count matrix and probability matrix
            count_matrix[prev_state_index][state_index] += 1
            update_probability_matrix(prev_state_index, count_matrix, num_states)
            prev_state_index = state_index

        counter += 1

        current_time = time.time()
        if current_time - trainingtime_Start > TRAINING_DURATION:
            trainingtime_End = time.time()
            duration = trainingtime_End - trainingtime_Start
            logging.info(f"The training period is: {duration}")
            migration_decision(state_index, no_of_states_ahead, num_states)

        # await asyncio.sleep(MONITOR_INTERVAL)

    ssh_client.close()

# Main execution
if __name__ == '__main__':
    if not SOURCE_VM or SOURCE_VM == 'localhost':
        logging.error('SOURCE_VM not configured. Set via environment variable: export SOURCE_VM=<host>')
        sys.exit(1)
    
    try:
        asyncio.run(run_iteration())
    except KeyboardInterrupt:
        logging.info('Monitoring interrupted by user')
    except Exception as e:
        logging.error(f'Error during execution: {e}')
        sys.exit(1)

