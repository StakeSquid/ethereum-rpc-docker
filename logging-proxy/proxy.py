from flask import Flask, request, jsonify
import requests
import sys
import os
import json

app = Flask(__name__)

# Target JSON-RPC server, e.g., an Ethereum node
TARGET_URL = os.getenv('TARGET_URL', 'http://host.docker.internal:8545')

@app.route('/', methods=['POST'])
def proxy():
    incoming = request.get_json()
    request_log = f"==> Request:\n{json.dumps(incoming, indent=2)}"

    response = requests.post(TARGET_URL, json=incoming)
    outgoing = response.json()

    log_lines = [request_log]

    if 'error' in outgoing:
        response_log = f"<== Response (Error):\n{json.dumps(outgoing, indent=2)}"
        log_lines.append(response_log)

    print('\n---\n'.join(log_lines), file=sys.stdout, flush=True)
        
    return jsonify(outgoing)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8545)
