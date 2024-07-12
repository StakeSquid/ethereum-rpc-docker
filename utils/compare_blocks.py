import argparse
import requests

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

# Iterate from the latest block down to the earliest
for block_number in range(latest_block_number, -1, -1):
    hash_1 = get_block_hash(rpc_url_1, block_number)
    hash_2 = get_block_hash(rpc_url_2, block_number)

    if hash_1 == hash_2:
        print(f"The first matching block is {block_number}")
        print(f"Block hash: {hash_1}")
        break
    else:
        print(f"Failed to match block {block_number} - {hash_1} - {hash_2}")
else:
    print("No matching block hash found.")

