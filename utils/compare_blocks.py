import argparse
import requests
import time

# Parse command-line arguments
parser = argparse.ArgumentParser(description='Compare block hashes from two Ethereum RPC endpoints.')
parser.add_argument('rpc_url_1', type=str, help='The first RPC URL')
parser.add_argument('rpc_url_2', type=str, help='The second RPC URL')
args = parser.parse_args()

# Define the RPC endpoints from the command-line arguments
rpc_url_1 = args.rpc_url_1
rpc_url_2 = args.rpc_url_2

# Define the JSON-RPC payload
def get_block_by_number_payload(block_number):
    return {
        "jsonrpc": "2.0",
        "method": "eth_getBlockByNumber",
        "params": [hex(block_number), False],
        "id": 1
    }

# Function to get the latest block number
def get_latest_block_number(rpc_url):
    response = requests.post(rpc_url, json={
        "jsonrpc": "2.0",
        "method": "eth_blockNumber",
        "params": [],
        "id": 1
    })
    result = response.json()
    return int(result['result'], 16)

# Function to get the block hash by block number
def get_block_hash(rpc_url, block_number):
    response = requests.post(rpc_url, json=get_block_by_number_payload(block_number))
    result = response.json()
    return result['result']['hash']

# Get the latest block number from the first RPC endpoint
latest_block_number = get_latest_block_number(rpc_url_1)

# Binary search-like approach to find the first matching block hash
low = 0
high = latest_block_number
first_matching_block = None

while low <= high:
    mid = (low + high) // 2
    hash_1 = get_block_hash(rpc_url_1, mid)
    hash_2 = get_block_hash(rpc_url_2, mid)

    if hash_1 == hash_2:
        first_matching_block = mid
        high = mid + 1  # Continue searching in the upper half
    else:
        low = mid - 1  # Continue searching in the lower half

    # Sleep for one second before the next comparison
    time.sleep(1)
        
if first_matching_block is not None:
    print(f"The first matching block is {first_matching_block}")
    print(f"Block hash: {get_block_hash(rpc_url_1, first_matching_block)}")
else:
    print("No matching block hash found.")
