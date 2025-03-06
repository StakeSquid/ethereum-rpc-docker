import os
import logging
import requests
import gzip
import io
from flask import Flask, request, Response

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

    # Forward headers (except Host), remove Accept-Encoding to force uncompressed response
    headers = {k: v for k, v in request.headers if k.lower() != "host"}
    headers.pop("Accept-Encoding", None)  # Prevent gzip response from upstream

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
            method=request.method, url=url, params=params, headers=headers, data=data, stream=True
        )

        # Handle gzip responses
        content_encoding = resp.headers.get("Content-Encoding", "")
        if "gzip" in content_encoding:
            logging.debug("Decompressing Gzip response")
            buffer = io.BytesIO(resp.content)
            with gzip.GzipFile(fileobj=buffer, mode="rb") as gzipped_file:
                decompressed_content = gzipped_file.read()
        else:
            decompressed_content = resp.content

        logging.debug(f"Response Status: {resp.status_code}")
        logging.debug(f"Response Headers: {dict(resp.headers)}")
        logging.debug(f"Response Body (first 500 chars): {decompressed_content[:500]}")

        # Remove gzip encoding from response headers
        response_headers = {k: v for k, v in resp.headers.items() if k.lower() != "content-encoding"}

        return Response(decompressed_content, resp.status_code, response_headers.items())

    except requests.RequestException as e:
        logging.error(f"Request failed: {e}")
        return Response(f"Error: {str(e)}", status=500)

if __name__ == "__main__":
    logging.info(f"Starting proxy on port 80, forwarding to {TARGET_URL}")
    app.run(host="0.0.0.0", port=80, debug=True)

