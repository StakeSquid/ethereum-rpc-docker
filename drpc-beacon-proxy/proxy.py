import os
from flask import Flask, request, Response
import requests

app = Flask(__name__)

# Read config from environment variables
DKEY = os.getenv("DKEY", "your-default-dkey")
NETWORK = os.getenv("NETWORK", "holesky")
TARGET_URL = f"https://lb.drpc.org/rest/eth-beacon-chain-{NETWORK}"

@app.route('/<path:subpath>', methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
def proxy(subpath):
    url = f"{TARGET_URL}/{subpath}"
    
    # Forward query params and add the dkey
    params = request.args.to_dict()
    params["dkey"] = DKEY

    # Forward headers (except Host) and body
    headers = {k: v for k, v in request.headers if k.lower() != "host"}
    data = request.get_data() if request.method in ["POST", "PUT", "PATCH"] else None

    # Forward the request
    resp = requests.request(
        method=request.method, url=url, params=params, headers=headers, data=data
    )

    # Return response with original status and headers
    return Response(resp.content, resp.status_code, resp.headers.items())

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
