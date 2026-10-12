#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
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


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _record_started_at(record: dict[str, Any]) -> datetime | None:
    raw = str(record.get("started_at") or "").strip()
    if not raw:
        return None
    try:
        started = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return started if started.tzinfo else started.replace(tzinfo=timezone.utc)


def latest_stage_record(project_dir: Path, stage: str, *, since: datetime | None = None) -> dict[str, Any]:
    """.qq/state/<stage>.json 里最近一条记录。

    给了 since 就只认这之后开跑的记录（started_at >= since）：脚本在写记录之前就退出时
    （找不到引擎、参数错），state 里留着的是上一次的结论，不能拿来当这一次的。
    """
    state_path = project_dir / ".qq" / "state" / f"{stage}.json"
    if not state_path.is_file():
        return {}
    try:
        record = load_json_file(state_path)
    except Exception:
        return {}
    if since is not None:
        started = _record_started_at(record)
        if started is None or started < since:
            return {}
    return record


# 进程非 0 退出时，记录里这几种状态都不能照搬：passed / warning 会报假绿，running 说明记录没收尾
_STATUSES_CONTRADICTED_BY_FAILURE = {"", "passed", "warning", "running"}


def normalize_run_status(value: Any, exit_code: int) -> str:
    """退出码优先：非 0 一律不报 passed / warning；退 0 才看记录写的是什么。"""
    raw = str(value or "").strip().lower()
    if exit_code != 0 and raw in _STATUSES_CONTRADICTED_BY_FAILURE:
        return "failed"
    return raw or "passed"


def stage_run_payload(
    project_dir: Path,
    stage: str,
    result: subprocess.CompletedProcess[str],
    *,
    since: datetime,
    engine: str,
    default_message: str,
) -> dict[str, Any]:
    """qq-compile.sh / qq-test.sh 跑完后给 MCP 的结论：只认 since 之后写下的记录，退出码优先。"""
    record = latest_stage_record(project_dir, stage, since=since)
    record_status = str(record.get("status") or "").strip().lower()
    status = normalize_run_status(record_status, result.returncode)
    # 记录被退出码推翻时，它的 summary（"... passed"）不能当这次的说明，改用这次的输出
    summary = str(record.get("summary") or "") if record_status == status else ""
    message = summary or result.stderr.strip() or result.stdout.strip() or default_message
    return {
        "ok": status in {"passed", "warning"},
        "state": status,
        "message": message,
        "engine": engine,
        "project_dir": str(project_dir),
        "backend": str(record.get("backend") or ""),
        "transport": str(record.get("transport") or ""),
        "failureCategory": str(record.get("failure_category") or ""),
        "recordPath": str(record.get("record_path") or ""),
        "stdout": result.stdout,
        "stderr": result.stderr,
        "exitCode": result.returncode,
    }


def _is_windows_launcher(path: Path) -> bool:
    """System32/bash.exe 是 WSL 启动器，WindowsApps 下是应用别名，都不是 Git Bash。"""
    system_root = os.environ.get("SystemRoot") or os.environ.get("windir") or r"C:\Windows"
    candidate = os.path.normcase(os.path.abspath(str(path)))
    root = os.path.normcase(os.path.abspath(system_root)).rstrip("/\\") + os.sep
    return candidate.startswith(root) or "windowsapps" in candidate.split(os.sep)


def resolve_bash() -> str:
    """跑 qq 的 .sh 用的 bash。

    macOS / Linux 上就是 PATH 里的 bash。Windows 上不能把裸 "bash" 交给 CreateProcess：
    它先搜 System32 再搜 PATH，装了 WSL 的机器会落到 System32/bash.exe（WSL 启动器），qq 脚本全跑进 Linux 子系统。
    这里只认 Git for Windows 的 bash（install.sh 声明的 Windows 依赖），按下面的顺序找：
      1. CLAUDE_CODE_GIT_BASH_PATH：Claude Code 自己找 Git Bash 用的变量，用户设了就是明确的选择；
      2. PATH 上第一个不是 WSL 启动器的 bash.exe：在 Git Bash 里起的服务走这条，跟终端用的是同一个 bash；
      3. 从 PATH 上的 git.exe 往上找 Git 安装根下的 bin/bash.exe（同 hooks/hook-dispatch.cmd 的第二步）：
         MCP 宿主多半是从 Windows 环境起的服务，Git 安装器默认只往 PATH 里放 Git/cmd（只有 git.exe、没有 bash.exe）；
         取 bin/bash.exe 而不是 usr/bin/bash.exe，是因为前者会自己把 /usr/bin 补进 PATH，sed、grep 才找得到；
      4. Git 的默认安装目录。
    shutil.which("bash") 不够：PATH 里 System32 通常排在 Git 前面，它照样先找到 WSL 启动器。
    """
    if os.name != "nt":
        return "bash"
    explicit = os.environ.get("CLAUDE_CODE_GIT_BASH_PATH", "").strip()
    if explicit and Path(explicit).is_file():
        return explicit
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry.strip():
            continue
        candidate = Path(entry.strip().strip('"')) / "bash.exe"
        if candidate.is_file() and not _is_windows_launcher(candidate):
            return str(candidate)
    git = shutil.which("git")
    if git:
        for parent in list(Path(git).resolve().parents)[:3]:
            candidate = parent / "bin" / "bash.exe"
            if candidate.is_file():
                return str(candidate)
    for variable, parts in (
        ("ProgramW6432", ("Git",)),
        ("ProgramFiles", ("Git",)),
        ("ProgramFiles(x86)", ("Git",)),
        ("LOCALAPPDATA", ("Programs", "Git")),
    ):
        base = os.environ.get(variable)
        if base:
            candidate = Path(base, *parts, "bin", "bash.exe")
            if candidate.is_file():
                return str(candidate)
    raise BridgeError(
        "COMMAND_NOT_FOUND",
        "Git Bash not found: qq scripts need the bash from Git for Windows "
        "(System32/bash.exe is the WSL launcher and is not used). Install Git for Windows or set CLAUDE_CODE_GIT_BASH_PATH.",
    )


def run_command(
    command: list[str],
    *,
    cwd: Path,
    timeout_sec: int | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """桥跑外部命令的唯一入口。command[0] 是 "bash" 时换成 resolve_bash() 找到的 bash（见那里的说明）。"""
    if command and command[0] == "bash":
        command = [resolve_bash(), *command[1:]]
    try:
        return subprocess.run(
            command,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
            env=env,
        )
    except FileNotFoundError as exc:
        raise BridgeError("COMMAND_NOT_FOUND", f"Command not found: {command[0]}", {"error": str(exc)}) from exc
    except OSError as exc:
        # 进程起不来：Windows 上直接执行 .sh 是 WinError 193，别处是没有执行位。按工具失败报，不冒到 JSON-RPC 层
        raise BridgeError("COMMAND_START_FAILED", f"Command could not start: {command[0]}", {"error": str(exc)}) from exc
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
