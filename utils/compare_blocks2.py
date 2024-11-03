import requests
import json

def get_block_by_number(endpoint, block_number):
    hex_block_number = hex(block_number)
    response = requests.post(
        endpoint,
        headers={"Content-Type": "application/json"},
        data=json.dumps({"jsonrpc": "2.0", "method": "eth_getBlockByNumber", "params": [hex_block_number, False], "id": 1})
    )
    response_data = response.json()
    return response_data['result']

def find_highest_matching_block(endpoint1, endpoint2, start_block):
    low = 0
    high = start_block
    highest_matching_block = None
    highest_matching_hash = None

    while low <= high:
        mid = (low + high) // 2
        
        block1 = get_block_by_number(endpoint1, mid)
        block2 = get_block_by_number(endpoint2, mid)

        if block1 is None or block2 is None:
            print(f"Block {mid} not found in one of the endpoints")
            high = mid - 1
            continue
        
        if block1['hash'] == block2['hash']:
            highest_matching_block = mid
            highest_matching_hash = block1['hash']
            low = mid + 1
        else:
            high = mid - 1

    if highest_matching_block is not None:
        # Linear search upwards from the highest known matching block to find the highest matching block
        while True:
            next_block1 = get_block_by_number(endpoint1, highest_matching_block + 1)
            next_block2 = get_block_by_number(endpoint2, highest_matching_block + 1)
            if next_block1 is None or next_block2 is None or next_block1['hash'] != next_block2['hash']:
                break
            highest_matching_block += 1
            highest_matching_hash = next_block1['hash']

        print(f"Matching block found at height {highest_matching_block}")
        print(f"Matching block hash: {highest_matching_hash}")
        print("I did it!")

        if next_block1 is not None and next_block2 is not None:
            print(f"Following block number {highest_matching_block + 1} does not match")
            print(f"Endpoint1 hash: {next_block1['hash']}")
            print(f"Endpoint2 hash: {next_block2['hash']}")
    else:
        print("No matching blocks found")

if __name__ == "__main__":
    endpoint1 = "https://rpc-de-15.stakesquid.eu/base"
    endpoint2 = "https://mainnet.base.org"
    start_block = 7945476
    find_highest_matching_block(endpoint1, endpoint2, start_block)
