from flask import Flask, request, jsonify
import requests
import sys
import os

app = Flask(__name__)

# Target JSON-RPC server, e.g., an Ethereum node
TARGET_URL = os.getenv('TARGET_URL', 'http://host.docker.internal:8545')

@app.route('/', methods=['POST'])
def proxy():
    incoming = request.get_json()
    print(f"==> Request:\n{incoming}", file=sys.stdout, flush=True)

    response = requests.post(TARGET_URL, json=incoming)
    outgoing = response.json()

    print(f"<== Response:\n{outgoing}", file=sys.stdout, flush=True)
    return jsonify(outgoing)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8545)
