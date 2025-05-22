#!/usr/bin/env python3
import sys
import json
import datetime
import shlex

def format_timestamp(ts):
    """
    Converts an ISO8601 timestamp (with trailing Z) into the format MM-DD|HH:MM:SS.mmm.
    Example: '2025-03-25T09:41:48.829633093Z' -> '03-25|09:41:48.829'
    """
    try:
        # Remove trailing "Z" if present and parse.
        dt = datetime.datetime.fromisoformat(ts.replace("Z", ""))
        formatted = dt.strftime("%m-%d|%H:%M:%S.%f")[:-3]
        return formatted
    except Exception:
        return ts

def format_timestamp_t(ts):
    """
    Converts a timestamp from key/value logs (e.g. '2025-03-26T12:06:31+0000')
    into MM-DD|HH:MM:SS.mmm. Note: It fixes the offset format if necessary.
    """
    try:
        # Fix offset if needed: insert a colon before the last two digits.
        if len(ts) >= 5 and (ts[-5] in ['+', '-'] and ts[-3] != ':'):
            ts = ts[:-2] + ':' + ts[-2:]
        dt = datetime.datetime.fromisoformat(ts)
        formatted = dt.strftime("%m-%d|%H:%M:%S.%f")[:-3]
        return formatted
    except Exception:
        return ts

def format_number(num):
    """Formats an integer (or numeric string) with commas."""
    try:
        return f"{int(num):,}"
    except Exception:
        return num

def shorten_hash(h):
    """
    Shortens a hash string by keeping the first 6 and last 5 characters.
    Example: '2544a06d361df25cb565b42b0ad0f7ee6cdaf0d714052a8cd3f0fdc3e3dad04a'
    becomes '2544a0..dad04a'.
    """
    if isinstance(h, str) and len(h) > 12:
        return f"{h[:6]}..{h[-5:]}"
    return h

def process_json_line(obj):
    # Extract main fields.
    severity = obj.get("severity", "INFO").upper()
    timestamp = format_timestamp(obj.get("timestamp", ""))
    message = obj.get("message", "")
    out = f"{severity} [{timestamp}] {message}"
    
    # These keys are already handled.
    skip_keys = {"severity", "timestamp", "message", "logger", "logging.googleapis.com/labels"}
    
    # If JSON includes block_number and block_Id, handle specially.
    if "block_number" in obj:
        out += f" number={format_number(obj['block_number'])}"
    if "block_Id" in obj:
        out += f" hash={shorten_hash(obj['block_Id'])}"
    
    for key in sorted(obj.keys()):
        if key in skip_keys or key in {"block_number", "block_Id"}:
            continue
        value = obj[key]
        if isinstance(value, int):
            value = format_number(value)
        out += f" {key}={value}"
    return out

def process_kv_line(line):
    """
    Parses a key=value style log (like t=, lvl=, msg=, etc.) and outputs
    a standardized log line in the form: "LEVEL [MM-DD|HH:MM:SS.mmm] message additional_keys=values".
    """
    try:
        tokens = shlex.split(line)
    except Exception:
        return line  # if shlex fails, return the original line.
    
    kv = {}
    for token in tokens:
        if '=' not in token:
            continue
        key, value = token.split("=", 1)
        kv[key] = value

    # Main fields:
    ts = kv.get("t", "")
    timestamp = format_timestamp_t(ts)
    severity = kv.get("lvl", "INFO").upper()
    message = kv.get("msg", "")
    
    out = f"{severity} [{timestamp}] {message}"
    
    # Special handling for IDs that are combined values (hash:number).
    # If the "id" field exists and contains a colon, split it into hash and number.
    if "id" in kv and ':' in kv["id"]:
        hash_part, num_part = kv["id"].split(":", 1)
        out += f" hash={shorten_hash(hash_part)} number={format_number(num_part)}"
        # Remove these keys so they don't get printed again.
        kv.pop("id")
    else:
        # If "hash" and "number" exist separately, process them.
        if "hash" in kv:
            out += f" hash={shorten_hash(kv['hash'])}"
            kv.pop("hash")
        if "number" in kv:
            out += f" number={format_number(kv['number'])}"
            kv.pop("number")
    
    # Keys to skip in extra printing.
    skip_keys = {"t", "lvl", "msg", "id", "hash", "number"}
    
    for key in sorted(kv.keys()):
        if key in skip_keys:
            continue
        value = kv[key]
        # Optionally, format numbers if the value is numeric.
        try:
            int_val = int(value)
            value = format_number(int_val)
        except Exception:
            pass
        out += f" {key}={value}"
    return out

def main():
    for line in sys.stdin:
        line = line.rstrip("\n")
        # First, try JSON.
        try:
            obj = json.loads(line)
            print(process_json_line(obj))
            continue
        except json.JSONDecodeError:
            pass

        # Next, if the line starts with "t=" or "lvl=", assume key-value style.
        if line.startswith("t=") or line.startswith("lvl="):
            print(process_kv_line(line))
            continue

        # Otherwise, assume it's already in standard plain text.
        print(line)

if __name__ == "__main__":
    main()
