#!/usr/bin/env python3
"""Minimal MCP stdio server used by StdioHealthCheck integration tests.

Modes (first argv):
  ok      — answers initialize and tools/list correctly
  silent  — never answers (timeout path)
  crash   — prints to stderr and exits before answering (error path)
  noisy   — prints a banner to stdout before behaving like `ok`
"""
import json
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "ok"

if mode == "crash":
    print("fatal: missing API key", file=sys.stderr)
    sys.exit(1)

if mode == "silent":
    time.sleep(60)
    sys.exit(0)

if mode == "noisy":
    print("Starting fake server v1.0...")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        reply = {
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "protocolVersion": message["params"]["protocolVersion"],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fake-server", "version": "1.0.0"},
            },
        }
    elif method == "tools/list":
        reply = {
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "tools": [
                    {"name": "echo", "description": "Echoes input back"},
                    {"name": "add", "description": "Adds two numbers"},
                ]
            },
        }
    elif method == "notifications/initialized":
        continue
    else:
        reply = {
            "jsonrpc": "2.0",
            "id": message.get("id"),
            "error": {"code": -32601, "message": "Method not found"},
        }
    print(json.dumps(reply))
    sys.stdout.flush()
