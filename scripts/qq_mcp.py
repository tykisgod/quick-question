#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from qq_engine import (
    bridge_host_state_file,
    bridge_script,
    bridge_server_name,
    display_name,
    resolve_project_engine,
    runtime_cache_dir,
)
from qq_bridge_common import (
    BridgeError,
    build_tool_result,
    latest_stage_record,
    normalize_run_status,
    run_command,
)
from godot_bridge import GodotBridge
from tykit_bridge import TykitBridge


JSONRPC_VERSION = "2.0"
SERVER_VERSION = "1.0.0"
GENERIC_PROTOCOL_VERSIONS = ["2024-11-05", "2024-10-07"]


class BridgeAdapter(Protocol):
    engine: str
    default_project_dir: str | None
    supported_protocol_versions: list[str]
    server_name: str
    instructions: str

    def list_tools(self) -> list[dict[str, Any]]:
        ...

    def call_tool(self, tool_name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        ...

    def tool_result(self, structured: dict[str, Any], is_error: bool | None = None) -> dict[str, Any]:
        ...

GENERIC_TOOL_DEFINITIONS: dict[str, dict[str, Any]] = {
    "qq_health": {
        "name": "qq_health",
        "title": "QQ Health",
        "description": "Check engine detection, bridge wiring, and generic qq runtime entry points for this project.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
            },
        },
    },
    "qq_doctor": {
        "name": "qq_doctor",
        "title": "QQ Doctor",
        "description": "Run qq-doctor and return the normalized provider/controller/runtime diagnosis for this project.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
            },
        },
    },
    "qq_project_state": {
        "name": "qq_project_state",
        "title": "QQ Project State",
        "description": "Read the normalized qq project-state payload for this engine project.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
            },
        },
    },
    "qq_compile": {
        "name": "qq_compile",
        "title": "QQ Compile",
        "description": "Run the project-local compile workflow for the current engine and return the latest structured run record.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "mode": {"type": "string", "enum": ["auto", "editor", "batch"]},
                "timeout_sec": {"type": "integer", "minimum": 1},
            },
        },
    },
    "qq_run_tests": {
        "name": "qq_run_tests",
        "title": "QQ Run Tests",
        "description": "Run the project-local test workflow for the current engine and return the latest structured run record.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "mode": {"type": "string"},
                "filter": {"type": "string"},
                "assembly_names": {"type": "array", "items": {"type": "string"}},
                "timeout_sec": {"type": "integer", "minimum": 1},
            },
        },
    },
    "qq_policy_check": {
        "name": "qq_policy_check",
        "title": "QQ Policy Check",
        "description": "Run deterministic engine-aware policy checks and return structured findings.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "files": {"type": "array", "items": {"type": "string"}},
            },
        },
    },
}


def resolve_project_dir(default_project_dir: str | None, value: Any = None) -> Path:
    candidate = str(value or default_project_dir or os.environ.get("QQ_PROJECT_DIR") or ".").strip()
    project_dir = Path(candidate).expanduser().resolve()
    engine = resolve_project_engine(project_dir)
    if not engine:
        raise BridgeError("PROJECT_NOT_SUPPORTED", f"No supported engine detected for project: {project_dir}")
    return project_dir


def build_generic_result(message: str, structured: dict[str, Any], *, is_error: bool | None = None) -> dict[str, Any]:
    return build_tool_result(structured, default_message=message, is_error=is_error)


class GenericScriptBridge:
    def __init__(self, project_dir: str, engine: str, profile: str | None = None):
        self.default_project_dir = project_dir
        self.engine = engine
        self.profile = profile or "standard"
        self.supported_protocol_versions = list(GENERIC_PROTOCOL_VERSIONS)
        self.server_name = bridge_server_name(engine) or f"qq-{engine}"
        self.instructions = (
            f"This server exposes generic qq tools for {display_name(engine) or engine}. "
            "Use qq_doctor and qq_project_state for routing/state, qq_compile and qq_run_tests for "
            "whole-workflow verification, and qq_policy_check for deterministic engine-specific checks."
        )

    def list_tools(self) -> list[dict[str, Any]]:
        return [dict(value) for value in GENERIC_TOOL_DEFINITIONS.values()]

    def tool_result(self, structured: dict[str, Any], is_error: bool | None = None) -> dict[str, Any]:
        message = str(structured.get("message") or structured.get("summary") or structured.get("category") or "qq operation completed")
        return build_generic_result(message, structured, is_error=is_error)

    def call_tool(self, tool_name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        args = arguments or {}
        if tool_name == "qq_health":
            return self.qq_health(args)
        if tool_name == "qq_doctor":
            return self.qq_doctor(args)
        if tool_name == "qq_project_state":
            return self.qq_project_state(args)
        if tool_name == "qq_compile":
            return self.qq_compile(args)
        if tool_name == "qq_run_tests":
            return self.qq_run_tests(args)
        if tool_name == "qq_policy_check":
            return self.qq_policy_check(args)
        raise BridgeError("UNKNOWN_TOOL", f"Unknown tool: {tool_name}")

    def resolve_project(self, arguments: dict[str, Any]) -> Path:
        project_dir = resolve_project_dir(self.default_project_dir, arguments.get("project_dir"))
        actual_engine = resolve_project_engine(project_dir)
        if actual_engine != self.engine:
            raise BridgeError(
                "ENGINE_MISMATCH",
                f"Bridge engine is {self.engine}, but project resolved to {actual_engine or 'unknown'}",
                {"project_dir": str(project_dir), "engine": actual_engine},
            )
        return project_dir

    def qq_health(self, arguments: dict[str, Any]) -> dict[str, Any]:
        project_dir = self.resolve_project(arguments)
        scripts = {
            "compile": project_dir / "scripts" / "qq-compile.sh",
            "test": project_dir / "scripts" / "qq-test.sh",
            "doctor": project_dir / "scripts" / "qq-doctor.py",
            "projectState": project_dir / "scripts" / "qq-project-state.py",
            "policyCheck": project_dir / "scripts" / "qq-policy-check.sh",
            "bridge": project_dir / "scripts" / (bridge_script(self.engine) or "qq_mcp.py"),
        }
        missing = [name for name, path in scripts.items() if not path.exists()]
        payload = {
            "ok": not missing,
            "engine": self.engine,
            "engineName": display_name(self.engine),
            "message": "qq runtime is ready" if not missing else "qq runtime is missing required entry points",
            "project_dir": str(project_dir),
            "runtimeCacheDir": runtime_cache_dir(self.engine),
            "bridgeServerName": self.server_name,
            "bridgeScript": str(scripts["bridge"]),
            "profile": self.profile,
            "missing": missing,
        }
        return payload

    def qq_doctor(self, arguments: dict[str, Any]) -> dict[str, Any]:
        project_dir = self.resolve_project(arguments)
        command = ["python3", str(project_dir / "scripts" / "qq-doctor.py"), "--project", str(project_dir)]
        result = run_command(command, cwd=project_dir)
        if result.returncode != 0:
            raise BridgeError("DOCTOR_FAILED", result.stderr.strip() or result.stdout.strip() or "qq-doctor failed")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise BridgeError("DOCTOR_FAILED", "qq-doctor returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise BridgeError("DOCTOR_FAILED", "qq-doctor returned a non-object payload")
        payload.setdefault("ok", True)
        payload.setdefault("message", "qq doctor completed")
        return payload

    def qq_project_state(self, arguments: dict[str, Any]) -> dict[str, Any]:
        project_dir = self.resolve_project(arguments)
        command = ["python3", str(project_dir / "scripts" / "qq-project-state.py"), "--project", str(project_dir), "--no-write"]
        result = run_command(command, cwd=project_dir)
        if result.returncode != 0:
            raise BridgeError("PROJECT_STATE_FAILED", result.stderr.strip() or result.stdout.strip() or "qq-project-state failed")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise BridgeError("PROJECT_STATE_FAILED", "qq-project-state returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise BridgeError("PROJECT_STATE_FAILED", "qq-project-state returned a non-object payload")
        payload.setdefault("ok", True)
        payload.setdefault("message", "qq project state loaded")
        return payload

    def qq_compile(self, arguments: dict[str, Any]) -> dict[str, Any]:
        project_dir = self.resolve_project(arguments)
        timeout_sec = int(arguments.get("timeout_sec") or 0) or None
        mode = str(arguments.get("mode") or "").strip().lower()
        command = ["bash", str(project_dir / "scripts" / "qq-compile.sh"), "--project", str(project_dir)]
        if timeout_sec:
            command.extend(["--timeout", str(timeout_sec)])
        if mode == "editor":
            command.append("--editor")
        elif mode == "batch":
            command.append("--batch")

        result = run_command(command, cwd=project_dir, timeout_sec=timeout_sec)
        record = latest_stage_record(project_dir, "compile")
        status = normalize_run_status(record.get("status"), result.returncode)
        summary = str(record.get("summary") or result.stderr.strip() or result.stdout.strip() or "Compile finished")
        return {
            "ok": status in {"passed", "warning"},
            "state": status,
            "message": summary,
            "engine": self.engine,
            "project_dir": str(project_dir),
            "backend": str(record.get("backend") or ""),
            "transport": str(record.get("transport") or ""),
            "failureCategory": str(record.get("failure_category") or ""),
            "recordPath": str(record.get("record_path") or ""),
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exitCode": result.returncode,
        }

    def qq_run_tests(self, arguments: dict[str, Any]) -> dict[str, Any]:
        project_dir = self.resolve_project(arguments)
        timeout_sec = int(arguments.get("timeout_sec") or 0) or None
        mode = str(arguments.get("mode") or "").strip()
        filter_value = str(arguments.get("filter") or "").strip()
        assembly_names = arguments.get("assembly_names") or []

        command = ["bash", str(project_dir / "scripts" / "qq-test.sh")]
        if mode:
            command.append(mode)
        command.extend(["--project", str(project_dir)])
        if filter_value:
            command.extend(["--filter", filter_value])
        if isinstance(assembly_names, list) and assembly_names:
            command.extend(["--assembly", ";".join(str(item) for item in assembly_names if str(item))])
        if timeout_sec:
            command.extend(["--timeout", str(timeout_sec)])

        result = run_command(command, cwd=project_dir, timeout_sec=timeout_sec)
        record = latest_stage_record(project_dir, "test")
        status = normalize_run_status(record.get("status"), result.returncode)
        summary = str(record.get("summary") or result.stderr.strip() or result.stdout.strip() or "Test run finished")
        return {
            "ok": status in {"passed", "warning"},
            "state": status,
            "message": summary,
            "engine": self.engine,
            "project_dir": str(project_dir),
            "backend": str(record.get("backend") or ""),
            "transport": str(record.get("transport") or ""),
            "failureCategory": str(record.get("failure_category") or ""),
            "recordPath": str(record.get("record_path") or ""),
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exitCode": result.returncode,
        }

    def qq_policy_check(self, arguments: dict[str, Any]) -> dict[str, Any]:
        project_dir = self.resolve_project(arguments)
        files = arguments.get("files") or []
        if files and not isinstance(files, list):
            raise BridgeError("INVALID_ARGUMENT", "qq_policy_check files must be an array of strings")
        command = ["bash", str(project_dir / "scripts" / "qq-policy-check.sh"), "--project", str(project_dir), "--json"]
        if isinstance(files, list):
            command.extend(str(item) for item in files if str(item))
        result = run_command(command, cwd=project_dir)
        if result.returncode != 0:
            raise BridgeError("POLICY_CHECK_FAILED", result.stderr.strip() or result.stdout.strip() or "qq-policy-check failed")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise BridgeError("POLICY_CHECK_FAILED", "qq-policy-check returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise BridgeError("POLICY_CHECK_FAILED", "qq-policy-check returned a non-object payload")
        payload.setdefault("message", "qq policy check completed")
        return payload


class CompositeBridge:
    def __init__(self, primary: BridgeAdapter, secondary: BridgeAdapter | None = None):
        self.primary = primary
        self.secondary = secondary
        self.engine = primary.engine
        self.default_project_dir = primary.default_project_dir
        self.supported_protocol_versions = list(primary.supported_protocol_versions)
        self.server_name = primary.server_name
        self.instructions = primary.instructions
        if secondary:
            for version in secondary.supported_protocol_versions:
                if version not in self.supported_protocol_versions:
                    self.supported_protocol_versions.append(version)
            self.instructions = f"{primary.instructions} Engine-specific rich tools remain available for this bridge."

    def list_tools(self) -> list[dict[str, Any]]:
        combined: dict[str, dict[str, Any]] = {}
        for tool in self.primary.list_tools():
            combined[str(tool.get("name") or "")] = tool
        if self.secondary:
            for tool in self.secondary.list_tools():
                combined.setdefault(str(tool.get("name") or ""), tool)
        return list(combined.values())

    def call_tool(self, tool_name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        primary_names = {str(tool.get("name") or "") for tool in self.primary.list_tools()}
        if tool_name in primary_names:
            return self.primary.call_tool(tool_name, arguments)
        if self.secondary:
            return self.secondary.call_tool(tool_name, arguments)
        raise BridgeError("UNKNOWN_TOOL", f"Unknown tool: {tool_name}")

    def tool_result(self, structured: dict[str, Any], is_error: bool | None = None) -> dict[str, Any]:
        return self.primary.tool_result(structured, is_error=is_error)


class UnityDelegateBridge:
    def __init__(self, project_dir: str, profile: str | None = None):
        self.engine = "unity"
        self.bridge = TykitBridge(default_project_dir=project_dir, profile=profile)
        self.default_project_dir = self.bridge.default_project_dir
        self.supported_protocol_versions = self.bridge.supported_protocol_versions
        self.server_name = bridge_server_name("unity") or "qq-unity"
        self.instructions = "This bridge also exposes typed Unity tools backed by tykit."

    def list_tools(self) -> list[dict[str, Any]]:
        return self.bridge.list_tools()

    def call_tool(self, tool_name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        return self.bridge.call_tool(tool_name, arguments or {})

    def tool_result(self, structured: dict[str, Any], is_error: bool | None = None) -> dict[str, Any]:
        return self.bridge.tool_result(structured, is_error=is_error)


class GodotDelegateBridge:
    def __init__(self, project_dir: str, profile: str | None = None):
        self.engine = "godot"
        self.bridge = GodotBridge(default_project_dir=project_dir, profile=profile)
        self.default_project_dir = self.bridge.default_project_dir
        self.supported_protocol_versions = self.bridge.supported_protocol_versions
        self.server_name = bridge_server_name("godot") or "qq-godot"
        self.instructions = "This bridge also exposes typed Godot editor tools backed by the built-in qq editor addon."

    def list_tools(self) -> list[dict[str, Any]]:
        return self.bridge.list_tools()

    def call_tool(self, tool_name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        return self.bridge.call_tool(tool_name, arguments or {})

    def tool_result(self, structured: dict[str, Any], is_error: bool | None = None) -> dict[str, Any]:
        return self.bridge.tool_result(structured, is_error=is_error)


class MCPServer:
    def __init__(self, bridge: BridgeAdapter, log_file: Path | None = None):
        self.bridge = bridge
        self.log_file = log_file
        self._initialized = False
        self._client_info: dict[str, Any] = {}
        self._negotiated_protocol_version = bridge.supported_protocol_versions[0]
        self._wire_format = "framed"

    def log(self, message: str) -> None:
        line = f"[{self.bridge.server_name}] {message}\n"
        if self.log_file is not None:
            self.log_file.parent.mkdir(parents=True, exist_ok=True)
            with self.log_file.open("a", encoding="utf-8") as handle:
                handle.write(line)
        else:
            sys.stderr.write(line)
            sys.stderr.flush()

    def send(self, message: dict[str, Any]) -> None:
        body = json.dumps(message, ensure_ascii=False).encode("utf-8")
        if self._wire_format == "jsonl":
            sys.stdout.buffer.write(body)
            sys.stdout.buffer.write(b"\n")
            sys.stdout.buffer.flush()
            return
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
        first_line = sys.stdin.buffer.readline()
        if not first_line:
            return None

        stripped = first_line.strip()
        if stripped.startswith((b"{", b"[")):
            self._wire_format = "jsonl"
            return json.loads(first_line.decode("utf-8"))

        headers: dict[str, str] = {}
        line = first_line
        while True:
            if line in {b"\r\n", b"\n"}:
                break
            try:
                key, value = line.decode("ascii").split(":", 1)
            except ValueError:
                return None
            headers[key.strip().lower()] = value.strip()
            line = sys.stdin.buffer.readline()
            if not line:
                return None

        self._wire_format = "framed"
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

    def record_initialize(self) -> None:
        if not self.bridge.default_project_dir:
            return
        project_dir = Path(self.bridge.default_project_dir).resolve()
        state_dir = project_dir / ".qq" / "state"
        state_dir.mkdir(parents=True, exist_ok=True)
        payload = {
            "serverName": self.bridge.server_name,
            "serverVersion": SERVER_VERSION,
            "projectDir": str(project_dir),
            "lastInitializeAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "protocolVersion": self._negotiated_protocol_version,
            "clientInfo": self._client_info,
        }
        target = state_dir / bridge_host_state_file(self.bridge.engine)
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def initialize_result(self, params: dict[str, Any]) -> dict[str, Any]:
        requested_version = str(params.get("protocolVersion") or "")
        self._client_info = params.get("clientInfo") or {}
        self._negotiated_protocol_version = self.negotiate_protocol(requested_version)
        self.record_initialize()
        return {
            "protocolVersion": self._negotiated_protocol_version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {
                "name": self.bridge.server_name,
                "version": SERVER_VERSION,
            },
            "instructions": self.bridge.instructions,
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


def build_bridge(project_dir: str, profile: str | None = None) -> BridgeAdapter:
    resolved_project = resolve_project_dir(project_dir)
    engine = resolve_project_engine(resolved_project)
    generic = GenericScriptBridge(str(resolved_project), engine, profile=profile)
    if engine == "unity":
        return CompositeBridge(generic, UnityDelegateBridge(str(resolved_project), profile=profile))
    if engine == "godot":
        return CompositeBridge(generic, GodotDelegateBridge(str(resolved_project), profile=profile))
    return generic


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="quick-question MCP bridge (stdio)")
    parser.add_argument("--project", default=os.environ.get("QQ_PROJECT_DIR") or ".", help="Supported engine project root")
    parser.add_argument("--profile", default=None, choices=["standard", "full"], help="Bridge tool profile")
    parser.add_argument("--log-file", help="Append bridge logs to a file instead of stderr")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        bridge = build_bridge(args.project, profile=args.profile)
    except BridgeError as exc:
        sys.stderr.write(f"[qq_mcp] {exc.message}\n")
        return 1

    server = MCPServer(bridge, Path(args.log_file).expanduser() if args.log_file else None)
    return server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
