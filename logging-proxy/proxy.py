from flask import Flask, request, jsonify
import requests
import sys
import os
import json
from flask_sockets import Sockets
import websocket
import gevent
import atexit # Import atexit
import copy # Import copy

app = Flask(__name__)
sockets = Sockets(app)

# Target URLs
TARGET_URL_HTTP = os.getenv('TARGET_URL', 'http://host.docker.internal:8545')
# Derive WebSocket URL from HTTP URL
TARGET_URL_WS = TARGET_URL_HTTP.replace('http://', 'ws://').replace('https://', 'wss://')

# --- New global variables ---
MAX_PARAMS_LOG_LENGTH = 5 # Max number of params to log before truncating
MAX_DATA_LOG_LENGTH = 100 # Max length for 'data' field in params before truncating
error_methods = set() # Set to store method names that resulted in errors
# --- End new global variables ---

# --- New function to print error summary ---
def print_error_summary():
    """Prints the set of methods that encountered errors."""
    if error_methods:
        print("\n--- Methods with Errors ---", file=sys.stdout)
        for method in sorted(list(error_methods)):
            print(f"- {method}", file=sys.stdout)
        print("--------------------------", file=sys.stdout, flush=True)
    else:
        print("\n--- No methods encountered errors during execution. ---", file=sys.stdout, flush=True)

# Register the summary function to run on exit
atexit.register(print_error_summary)
# --- End new function ---

@app.route('/', methods=['POST'])
def proxy():
    incoming = request.get_json()
    
    # Create a deep copy for logging to allow modification without affecting the actual request
    # Use deepcopy to handle nested structures like params containing dictionaries
    log_incoming = copy.deepcopy(incoming) if isinstance(incoming, dict) else incoming

    # Truncate params and data within params for logging
    if isinstance(log_incoming, dict) and 'params' in log_incoming and isinstance(log_incoming['params'], list):
        original_params_len = len(incoming['params']) # Use original length for truncation message

        # --- Start: Truncate 'data' field within params ---
        for i, param in enumerate(log_incoming['params']):
            if isinstance(param, dict) and 'data' in param and isinstance(param['data'], str):
                if len(param['data']) > MAX_DATA_LOG_LENGTH:
                    param['data'] = param['data'][:MAX_DATA_LOG_LENGTH] + f"... (truncated {len(param['data']) - MAX_DATA_LOG_LENGTH} chars)"
            # Stop processing params if we are already at the truncation limit for the list itself
            if i >= MAX_PARAMS_LOG_LENGTH -1:
                 break
        # --- End: Truncate 'data' field within params ---

        # Truncate the params list itself if it's too long
        if original_params_len > MAX_PARAMS_LOG_LENGTH:
            log_incoming['params'] = log_incoming['params'][:MAX_PARAMS_LOG_LENGTH] + [f"... (truncated {original_params_len - MAX_PARAMS_LOG_LENGTH} more params)"]

    # Use the potentially modified log_incoming for the request log string
    request_log = f"==> Request:\n{json.dumps(log_incoming, indent=2)}"

    # Send the original 'incoming' data to the target
    response = requests.post(TARGET_URL_HTTP, json=incoming)
    outgoing = response.json()

    # Initialize log_lines here, decide what to include based on error status
    log_lines = []

    if 'error' in outgoing:
        # For errors, log both request and response
        log_lines.append(request_log)
        response_log = f"<== Response (Error):\n{json.dumps(outgoing, indent=2)}"
        log_lines.append(response_log)
        # Track the method name if an error occurred and method exists in request
        if isinstance(incoming, dict) and 'method' in incoming:
            error_methods.add(incoming['method'])
    else:
        # For success, log only the success message with the method name
        method_name = "unknown_method" # Default if not found
        if isinstance(incoming, dict) and 'method' in incoming:
            method_name = incoming['method']
        response_log = f"<== Response (Success): Method '{method_name}' completed."
        log_lines.append(response_log)

    print('\n---\n'.join(log_lines), file=sys.stdout, flush=True)
        
    return jsonify(outgoing)

# WebSocket handler moved to '/ws'
@sockets.route('/ws') # <--- Changed path from '/' to '/ws'
def proxy_socket(ws):
    """Handles incoming WebSocket connections and relays messages."""
    print("==> WebSocket connection received on /ws", file=sys.stdout, flush=True) # <--- Updated log message
    target_ws = None
    try:
        # Connect to the target WebSocket server (TARGET_URL_WS usually doesn't need a path)
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
                        # --- Log WS message from client (optional, can be verbose) ---
                        # try:
                        #     msg_data = json.loads(message)
                        #     print(f"==> WS Client Message:\n{json.dumps(msg_data, indent=2)}", file=sys.stdout, flush=True)
                        # except json.JSONDecodeError:
                        #     print(f"==> WS Client Message (non-JSON): {message}", file=sys.stdout, flush=True)
                        # --- End log ---
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
                         # --- Log WS message from target (optional, can be verbose) ---
                        # try:
                        #     msg_data = json.loads(message)
                        #     print(f"<== WS Target Message:\n{json.dumps(msg_data, indent=2)}", file=sys.stdout, flush=True)
                        #     # Check for errors in WS messages if they follow JSON-RPC format
                        #     if isinstance(msg_data, dict) and 'error' in msg_data and 'id' in msg_data:
                        #          # Note: Correlating WS errors back to specific request methods is harder
                        #          #       as requests/responses are asynchronous. We won't add to error_methods here.
                        #          pass 
                        # except json.JSONDecodeError:
                        #     print(f"<== WS Target Message (non-JSON): {message}", file=sys.stdout, flush=True)
                        # --- End log ---
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
    # Add graceful shutdown handling if possible with gevent (optional but good practice)
    # gevent.signal_handler(signal.SIGTERM, server.stop) 
    # gevent.signal_handler(signal.SIGINT, server.stop) # Handle Ctrl+C
    try:
        server.serve_forever()
    except KeyboardInterrupt: # Catch Ctrl+C if signal handlers aren't used/working
        print("\nCtrl+C detected, shutting down.", file=sys.stdout)
    finally:
        # The atexit handler will run automatically on normal exit.
        pass 
