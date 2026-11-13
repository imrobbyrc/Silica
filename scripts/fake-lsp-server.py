#!/usr/bin/env python3
"""A minimal fake language server over stdio, for Silica's LSP integration test.

Speaks just enough of the Language Server Protocol to exercise Silica's client:
initialize/initialized handshake, textDocument/didOpen|didChange|didClose sync,
and textDocument/definition. The definition answer is scripted via environment
variables:

    FAKE_LSP_TARGET_URI   file:// URI of the definition location to return
    FAKE_LSP_RANGE        "startLine:startCol:endLine:endCol" (0-based, UTF-16)
    FAKE_LSP_REQUEST_LOG  optional file; didOpen/didChange notifications and
                          definition requests are appended as JSON lines

Unknown requests are answered with methodNotFound. Runs until it receives
`exit` (after `shutdown`), or stdin closes.
"""

import json
import os
import sys


def read_message():
    """Reads one LSP message from stdin; returns None at EOF."""
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, _, value = line.decode("ascii", "replace").partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers.get("content-length", 0))
    body = sys.stdin.buffer.read(length) if length else b""
    return json.loads(body.decode("utf-8"))


def write_message(payload):
    body = json.dumps(payload).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def reply(msg_id, result):
    write_message({"jsonrpc": "2.0", "id": msg_id, "result": result})


def reply_error(msg_id, code, message):
    write_message({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})


def log_event(event):
    log_path = os.environ.get("FAKE_LSP_REQUEST_LOG")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(event) + "\n")


def definition_result():
    uri = os.environ["FAKE_LSP_TARGET_URI"]
    sl, sc, el, ec = (int(part) for part in os.environ["FAKE_LSP_RANGE"].split(":"))
    return [
        {
            "uri": uri,
            "range": {
                "start": {"line": sl, "character": sc},
                "end": {"line": el, "character": ec},
            },
        }
    ]


def main():
    initialized = False
    while True:
        message = read_message()
        if message is None:
            return 1  # stdin closed without exit: treat as abnormal
        method = message.get("method", "")
        params = message.get("params") or {}
        if "id" in message:  # request
            if method == "initialize":
                initialized = True
                reply(message["id"], {"capabilities": {"definitionProvider": True}})
            elif method == "shutdown":
                reply(message["id"], None)
            elif method == "textDocument/definition":
                log_event({"method": method, "params": params})
                if initialized:
                    reply(message["id"], definition_result())
                else:
                    reply_error(message["id"], -32002, "server not initialized")
            elif method == "":
                # No method with an id: a response to our (unused) server-to-client
                # traffic; ignore it.
                continue
            else:
                reply_error(message["id"], -32601, "method not found: %s" % method)
        else:  # notification
            if method == "exit":
                return 0
            if method in {"textDocument/didOpen", "textDocument/didChange"}:
                log_event({"method": method, "params": params})
            # initialized/didClose/$/... : nothing to do


if __name__ == "__main__":
    sys.exit(main())
