#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any


class BridgeError(Exception):
    def __init__(self, category: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.category = category
        self.message = message
        self.details = details or {}

    def to_result(self) -> dict[str, Any]:
        result = {
            "ok": False,
            "category": self.category,
            "message": self.message,
        }
        if self.details:
            result["details"] = self.details
        return result


def pretty_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)


def load_json_file(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"Expected JSON object in {path}")
    return payload


def latest_stage_record(project_dir: Path, stage: str) -> dict[str, Any]:
    state_path = project_dir / ".qq" / "state" / f"{stage}.json"
    if state_path.is_file():
        try:
            return load_json_file(state_path)
        except Exception:
            return {}
    return {}


def normalize_run_status(value: Any, exit_code: int) -> str:
    raw = str(value or "").strip().lower()
    if raw:
        return raw
    return "passed" if exit_code == 0 else "failed"


def run_command(command: list[str], *, cwd: Path, timeout_sec: int | None = None) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
    except FileNotFoundError as exc:
        raise BridgeError("COMMAND_NOT_FOUND", f"Command not found: {command[0]}", {"error": str(exc)}) from exc
    except subprocess.TimeoutExpired as exc:
        raise BridgeError(
            "COMMAND_TIMEOUT",
            f"Command timed out: {' '.join(command)}",
            {
                "timeout_sec": timeout_sec,
                "stdout": exc.stdout or "",
                "stderr": exc.stderr or "",
            },
        ) from exc


def build_tool_result(structured: dict[str, Any], *, default_message: str, is_error: bool | None = None) -> dict[str, Any]:
    error_flag = bool(structured.get("ok") is False) if is_error is None else is_error
    message = str(structured.get("message") or structured.get("summary") or structured.get("category") or default_message)
    return {
        "content": [{"type": "text", "text": f"{message}\n\n{pretty_json(structured)}"}],
        "structuredContent": structured,
        "isError": error_flag,
    }
