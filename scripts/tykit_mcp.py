#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from tykit_bridge import BridgeError, TykitBridge


JSONRPC_VERSION = "2.0"
SERVER_NAME = "tykit-mcp"
SERVER_VERSION = "1.0.0"


class MCPServer:
    def __init__(self, bridge: TykitBridge, log_file: Path | None = None):
        self.bridge = bridge
        self.log_file = log_file
        self._initialized = False
        self._client_info: dict[str, Any] = {}
        self._negotiated_protocol_version = bridge.supported_protocol_versions[0]

    def log(self, message: str) -> None:
        line = f"[tykit-mcp] {message}\n"
        if self.log_file is not None:
            self.log_file.parent.mkdir(parents=True, exist_ok=True)
            with self.log_file.open("a", encoding="utf-8") as handle:
                handle.write(line)
        else:
            sys.stderr.write(line)
            sys.stderr.flush()

    def send(self, message: dict[str, Any]) -> None:
        body = json.dumps(message, ensure_ascii=False).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        sys.stdout.buffer.write(header)
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()

    def send_response(self, request_id: Any, result: dict[str, Any]) -> None:
        self.send({"jsonrpc": JSONRPC_VERSION, "id": request_id, "result": result})

    def send_error(self, request_id: Any, code: int, message: str, data: Any | None = None) -> None:
        payload: dict[str, Any] = {
            "jsonrpc": JSONRPC_VERSION,
            "id": request_id,
            "error": {"code": code, "message": message},
        }
        if data is not None:
            payload["error"]["data"] = data
        self.send(payload)

    def read_message(self) -> dict[str, Any] | None:
        headers: dict[str, str] = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            if line in {b"\r\n", b"\n"}:
                break
            try:
                key, value = line.decode("ascii").split(":", 1)
            except ValueError:
                continue
            headers[key.strip().lower()] = value.strip()

        try:
            content_length = int(headers.get("content-length", "0"))
        except ValueError:
            return None
        if content_length <= 0:
            return None

        body = sys.stdin.buffer.read(content_length)
        if not body:
            return None
        return json.loads(body.decode("utf-8"))

    def negotiate_protocol(self, requested: str) -> str:
        if requested in self.bridge.supported_protocol_versions:
            return requested
        return self.bridge.supported_protocol_versions[0]

    def initialize_result(self, params: dict[str, Any]) -> dict[str, Any]:
        requested_version = str(params.get("protocolVersion") or "")
        self._client_info = params.get("clientInfo") or {}
        self._negotiated_protocol_version = self.negotiate_protocol(requested_version)
        return {
            "protocolVersion": self._negotiated_protocol_version,
            "capabilities": {
                "tools": {"listChanged": False}
            },
            "serverInfo": {
                "name": SERVER_NAME,
                "version": SERVER_VERSION,
            },
            "instructions": (
                "This server exposes tykit-backed Unity tools. Prefer unity_compile and "
                "unity_run_tests for whole workflows, use unity_batch to reduce round trips, "
                "and reserve unity_raw_command for edge cases."
            ),
        }

    def handle_request(self, message: dict[str, Any]) -> None:
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") or {}

        if method == "initialize":
            if not isinstance(params, dict):
                self.send_error(request_id, -32602, "initialize params must be an object")
                return
            self.send_response(request_id, self.initialize_result(params))
            return

        if method == "ping":
            self.send_response(request_id, {})
            return

        if not self._initialized:
            self.send_error(request_id, -32002, "Server not initialized")
            return

        if method == "tools/list":
            self.send_response(request_id, {"tools": self.bridge.list_tools()})
            return

        if method == "tools/call":
            if not isinstance(params, dict):
                self.send_error(request_id, -32602, "tools/call params must be an object")
                return
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if not isinstance(name, str) or not name:
                self.send_error(request_id, -32602, "tools/call params.name must be a string")
                return
            if not isinstance(arguments, dict):
                self.send_error(request_id, -32602, "tools/call params.arguments must be an object")
                return
            try:
                structured = self.bridge.call_tool(name, arguments)
            except BridgeError as exc:
                if exc.category in {"UNKNOWN_TOOL", "INVALID_ARGUMENT"}:
                    self.send_error(request_id, -32602, exc.message, exc.details or None)
                    return
                self.send_response(request_id, self.bridge.tool_result(exc.to_result(), is_error=True))
                return
            self.send_response(request_id, self.bridge.tool_result(structured))
            return

        self.send_error(request_id, -32601, f"Method not found: {method}")

    def handle_notification(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        if method == "notifications/initialized":
            self._initialized = True
            return
        if method == "notifications/cancelled":
            return

    def serve_forever(self) -> int:
        while True:
            message = self.read_message()
            if message is None:
                return 0
            try:
                if "id" in message:
                    self.handle_request(message)
                else:
                    self.handle_notification(message)
            except Exception as exc:  # pragma: no cover - defensive catch for stdio loop
                self.log(f"Unhandled server error: {exc}\n{traceback.format_exc()}")
                if "id" in message:
                    self.send_error(message.get("id"), -32603, "Internal server error")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="tykit MCP bridge (stdio)")
    parser.add_argument("--project", help="Default Unity project root")
    parser.add_argument("--profile", default=None, choices=["standard", "full"], help="Tool profile to expose")
    parser.add_argument("--log-file", help="Append bridge logs to a file instead of stderr")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.project:
        os.environ["TYKIT_PROJECT_DIR"] = args.project
    if args.profile:
        os.environ["TYKIT_PROFILE"] = args.profile

    try:
        bridge = TykitBridge(default_project_dir=args.project, profile=args.profile)
    except BridgeError as exc:
        sys.stderr.write(f"[tykit-mcp] {exc.message}\n")
        return 1

    server = MCPServer(bridge, Path(args.log_file).expanduser() if args.log_file else None)
    return server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
