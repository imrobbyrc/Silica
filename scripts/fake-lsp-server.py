#!/usr/bin/env python3
"""A minimal fake language server over stdio, for Silica's LSP integration test.

Speaks just enough of the Language Server Protocol to exercise Silica's client:
initialize/initialized handshake, textDocument/didOpen|didChange|didClose sync,
and textDocument/definition. It probes workspace configuration and folders,
and publishes diagnostics for the integration self-test.
The definition answer is scripted via environment variables:

    FAKE_LSP_TARGET_URI   file:// URI of the definition location to return
    FAKE_LSP_RANGE        "startLine:startCol:endLine:endCol" (0-based, UTF-16)
    FAKE_LSP_COMPLETIONS_RESULT        optional JSON array: completion items
    FAKE_LSP_COMPLETIONS_RESULT_FILE   optional per-request override
    FAKE_LSP_COMPLETION_DELAY   optional seconds to delay the completion reply
    FAKE_LSP_COMPLETION_DELAY_FILE     optional per-request override
    FAKE_LSP_REQUEST_LOG  optional file; didOpen/didChange notifications and
                          definition requests are appended as JSON lines

Unknown requests are answered with methodNotFound. Runs until it receives
`exit` (after `shutdown`), or stdin closes.
"""

import json
import os
import sys
import time


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


def send_request(msg_id, method, params):
    write_message({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params})


def log_event(event):
    path = os.environ.get("FAKE_LSP_REQUEST_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as log:
            log.write(json.dumps(event) + "\n")


def publish_diagnostics(uri, diagnostics):
    write_message({
        "jsonrpc": "2.0",
        "method": "textDocument/publishDiagnostics",
        "params": {"uri": uri, "diagnostics": diagnostics},
    })


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


def scripted_value(name, default=None):
    """Reads a scripted value live: from <name>_FILE if set (per-request),
    else from <name> (frozen at server spawn)."""
    path = os.environ.get(name + "_FILE")
    if path:
        try:
            with open(path, encoding="utf-8") as f:
                return f.read()
        except OSError:
            return default
    return os.environ.get(name, default)


def scripted_reply(msg_id, method, env_name, delay_name):
    """Answers completion from a scripted JSON value, optionally delayed.

    Returns True when handled (no scripted value at all means 'not handled').
    """
    raw = scripted_value(env_name)
    if raw is None:
        return False
    delay = float(scripted_value(delay_name, "0") or 0)
    if delay:
        time.sleep(delay)
    result = None
    if raw:
        try:
            result = json.loads(raw)
        except json.JSONDecodeError:
            # Bad scripted value: answer empty instead of killing the pipe.
            log_event({"method": method, "error": "bad scripted JSON"})
    log_event({"method": method, "delay": delay})
    reply(msg_id, result)
    return True


def main():
    initialized = False
    root_uri = None
    try:
        return run_server_loop()
    except Exception:
        # A crash here kills the JSON-RPC pipe; surface it for debugging.
        import traceback
        log_event({"method": "FAKE SERVER CRASH", "trace": traceback.format_exc()})
        raise


def run_server_loop():
    initialized = False
    root_uri = None
    while True:
        message = read_message()
        if message is None:
            return 1  # stdin closed without exit: treat as abnormal
        method = message.get("method", "")
        params = message.get("params") or {}
        if "id" in message:  # request
            if method == "initialize":
                initialized = True
                root_uri = params.get("rootUri")
                log_event({"method": method, "params": params})
                reply(message["id"], {"capabilities": {
                    "definitionProvider": True,
                    "completionProvider": {"triggerCharacters": ["."]},
                }})
            elif method == "shutdown":
                reply(message["id"], None)
            elif method == "textDocument/definition":
                log_event({"method": method, "params": params})
                if initialized:
                    reply(message["id"], definition_result())
                else:
                    reply_error(message["id"], -32002, "server not initialized")
            elif method == "textDocument/completion":
                if scripted_reply(message["id"], method, "FAKE_LSP_COMPLETIONS_RESULT", "FAKE_LSP_COMPLETION_DELAY"):
                    pass
                elif initialized:
                    reply(message["id"], [])
                else:
                    reply_error(message["id"], -32002, "server not initialized")
            elif method == "":
                response_methods = {
                    1001: "workspace/configuration/response",
                    1002: "workspace/workspaceFolders/response",
                }
                response_method = response_methods.get(message["id"])
                if response_method:
                    log_event({
                        "method": response_method,
                        "result": message.get("result"),
                        "error": message.get("error"),
                    })
            else:
                reply_error(message["id"], -32601, "method not found: %s" % method)
        else:  # notification
            if method == "exit":
                return 0
            if method == "initialized":
                send_request(1001, "workspace/configuration", {
                    "items": [
                        {"scopeUri": root_uri, "section": "silica.test.one"},
                        {"scopeUri": root_uri, "section": "silica.test.two"},
                    ],
                })
                send_request(1002, "workspace/workspaceFolders", {})
            elif method == "textDocument/didOpen":
                log_event({"method": method, "params": params})
                publish_diagnostics(params["textDocument"]["uri"], [
                    {
                        "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
                        "severity": 1,
                        "message": "fake error",
                    },
                    {
                        "range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 2}},
                        "severity": 2,
                        "message": "fake warning",
                    },
                ])
            elif method == "textDocument/didChange":
                log_event({"method": method, "params": params})
                publish_diagnostics(params["textDocument"]["uri"], [])
            # initialized/didClose/$/... : nothing to do


if __name__ == "__main__":
    sys.exit(main())
