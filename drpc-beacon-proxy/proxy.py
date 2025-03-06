import os
import logging
from flask import Flask, request, Response
import requests

# Setup logging
logging.basicConfig(level=logging.DEBUG, format="%(asctime)s [%(levelname)s] %(message)s")

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

    # Debug logs
    logging.debug(f"Incoming request: {request.method} {request.path}")
    logging.debug(f"Forwarding request to: {url}")
    logging.debug(f"Headers: {headers}")
    logging.debug(f"Query Params: {params}")
    if data:
        logging.debug(f"Request Body: {data.decode('utf-8')}")

    try:
        # Forward the request
        resp = requests.request(
            method=request.method, url=url, params=params, headers=headers, data=data
        )

        logging.debug(f"Response Status: {resp.status_code}")
        logging.debug(f"Response Headers: {dict(resp.headers)}")
        logging.debug(f"Response Body: {resp.text[:500]}")  # Limit log size

        return Response(resp.content, resp.status_code, resp.headers.items())
    except requests.RequestException as e:
        logging.error(f"Request failed: {e}")
        return Response(f"Error: {str(e)}", status=500)

if __name__ == "__main__":
    logging.info(f"Starting proxy on port 80, forwarding to {TARGET_URL}")
    app.run(host="0.0.0.0", port=80, debug=True)
