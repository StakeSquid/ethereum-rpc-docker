from flask import Flask, request, jsonify
import requests
import sys
import os
import json
from flask_sockets import Sockets
import websocket
import gevent

app = Flask(__name__)
sockets = Sockets(app)

# Target URLs
TARGET_URL_HTTP = os.getenv('TARGET_URL', 'http://host.docker.internal:8545')
# Derive WebSocket URL from HTTP URL
TARGET_URL_WS = TARGET_URL_HTTP.replace('http://', 'ws://').replace('https://', 'wss://')

@app.route('/', methods=['POST'])
def proxy():
    incoming = request.get_json()
    request_log = f"==> Request:\n{json.dumps(incoming, indent=2)}"

    response = requests.post(TARGET_URL_HTTP, json=incoming)
    outgoing = response.json()

    log_lines = [request_log]

    if 'error' in outgoing:
        response_log = f"<== Response (Error):\n{json.dumps(outgoing, indent=2)}"
        log_lines.append(response_log)

    print('\n---\n'.join(log_lines), file=sys.stdout, flush=True)
        
    return jsonify(outgoing)

# New WebSocket handler
@sockets.route('/')
def proxy_socket(ws):
    """Handles incoming WebSocket connections and relays messages."""
    print("==> WebSocket connection received", file=sys.stdout, flush=True)
    target_ws = None
    try:
        # Connect to the target WebSocket server
        target_ws = websocket.create_connection(TARGET_URL_WS)
        print(f"==> WebSocket connection established to {TARGET_URL_WS}", file=sys.stdout, flush=True)

        # Use gevent greenlets to relay messages concurrently
        from gevent import spawn

        def relay_to_target():
            """Relay messages from the client to the target."""
            try:
                while not ws.closed and target_ws.connected:
                    message = ws.receive()
                    if message is not None:
                        target_ws.send(message)
                    else: # Client closed
                        break
            except websocket.WebSocketConnectionClosedException:
                print("<== WebSocket client connection closed.", file=sys.stdout, flush=True)
            except Exception as e:
                print(f"Error receiving from client or sending to target: {e}", file=sys.stderr, flush=True)
            finally:
                if target_ws and target_ws.connected:
                    target_ws.close()

        def relay_to_client():
            """Relay messages from the target to the client."""
            try:
                while target_ws.connected and not ws.closed:
                    message = target_ws.recv()
                    if message:
                        ws.send(message)
                    else: # Target closed
                        break
            except websocket.WebSocketConnectionClosedException:
                print("<== WebSocket target connection closed.", file=sys.stdout, flush=True)
            except Exception as e:
                print(f"Error receiving from target or sending to client: {e}", file=sys.stderr, flush=True)
            finally:
                if not ws.closed:
                    ws.close()

        # Start the relay greenlets
        g_to_target = spawn(relay_to_target)
        g_to_client = spawn(relay_to_client)

        # Wait for both relays to complete
        gevent.joinall([g_to_target, g_to_client], raise_error=False) # Don't raise errors here, already printed

    except websocket.WebSocketException as e:
        print(f"<== WebSocket connection to target {TARGET_URL_WS} failed: {e}", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"An unexpected error occurred in WebSocket proxy: {e}", file=sys.stderr, flush=True)
    finally:
        # Ensure connections are closed
        if target_ws and target_ws.connected:
            target_ws.close()
        if not ws.closed:
            ws.close()
        print("<== WebSocket handler finished", file=sys.stdout, flush=True)

if __name__ == '__main__':
    # Use gevent-websocket server instead of Flask's default development server
    from gevent import pywsgi
    from geventwebsocket.handler import WebSocketHandler
    print(f"Starting server on 0.0.0.0:8545 supporting HTTP and WebSocket...")
    print(f"HTTP proxying to: {TARGET_URL_HTTP}")
    print(f"WebSocket proxying to: {TARGET_URL_WS}")
    server = pywsgi.WSGIServer(('0.0.0.0', 8545), app, handler_class=WebSocketHandler)
    server.serve_forever()
