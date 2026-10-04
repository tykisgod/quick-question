#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from qq_engine import codex_server_prefix, default_slug, known_engines, resolve_project_engine
from qq_internal_config import ConfigError, resolve_project_config


SCRIPT_DIR = Path(__file__).resolve().parent


def resolve_project_dir(value: str) -> Path:
    return Path(value).expanduser().resolve()


def slugify(value: str, engine: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or default_slug(engine)


def codex_server_name(project_dir: Path) -> str:
    engine = resolve_project_engine(project_dir) or "unity"
    digest = hashlib.sha1(str(project_dir).encode("utf-8")).hexdigest()[:8]
    return f"{codex_server_prefix(engine)}{slugify(project_dir.name, engine)}-{digest}"


def load_worktree_status(project_dir: Path) -> dict[str, Any]:
    helper = SCRIPT_DIR / "qq-worktree.py"
    if not helper.is_file():
        return {}
    result = subprocess.run(
        [sys.executable, str(helper), "status", "--project", str(project_dir)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return {}
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


def run_codex(arguments: list[str], *, check: bool) -> subprocess.CompletedProcess[str]:
    # Windows: subprocess.run can't exec .CMD/.BAT files via bare name without
    # PATHEXT resolution; use shutil.which to get the resolved path. shutil.which
    # has already been called by callers that gate on codex availability, so
    # falling back to "codex" here is fine for Linux/macOS.
    codex_exe = shutil.which("codex") or "codex"
    return subprocess.run(
        [codex_exe, *arguments],
        check=check,
        capture_output=True,
        text=True,
    )


def list_registered_qq_bridge_servers() -> list[str]:
    if shutil.which("codex") is None:
        return []
    result = run_codex(["mcp", "list"], check=False)
    if result.returncode != 0:
        return []
    lines = [line.rstrip() for line in result.stdout.splitlines() if line.strip()]
    if len(lines) <= 1:
        return []
    prefixes: set[str] = set()
    for engine in known_engines():
        prefixes.add(codex_server_prefix(engine))
    names: list[str] = []
    for line in lines[1:]:
        name = line.split()[0]
        if any(name.startswith(prefix) for prefix in prefixes):
            names.append(name)
    return names


def fetch_mcp_registration(name: str) -> dict[str, Any]:
    result = run_codex(["mcp", "get", name, "--json"], check=False)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip() or f"codex mcp get {name} failed")
    payload = json.loads(result.stdout)
    return payload if isinstance(payload, dict) else {}


def remove_mcp_registration(name: str) -> None:
    result = run_codex(["mcp", "remove", name], check=False)
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout).strip() or f"codex mcp remove {name} failed")


def restore_mcp_registration(registration: dict[str, Any]) -> None:
    name = str(registration.get("name") or "").strip()
    transport = registration.get("transport") or {}
    if not name or not isinstance(transport, dict):
        return
    if transport.get("type") != "stdio":
        raise RuntimeError(f"Unsupported MCP transport for restore: {name}")
    command = str(transport.get("command") or "").strip()
    args = [str(item) for item in (transport.get("args") or [])]
    if not command:
        raise RuntimeError(f"Missing command for MCP restore: {name}")
    run_codex(["mcp", "add", name, "--", command, *args], check=True)


@contextmanager
def isolate_project_mcp_server(project_dir: Path, dry_run: bool = False):
    current_server = codex_server_name(project_dir)
    qq_servers = list_registered_qq_bridge_servers()
    suspended = [name for name in qq_servers if name != current_server]
    payload = {
        "enabledServer": current_server,
        "registeredServers": qq_servers,
        "suspendedServers": suspended,
        "applied": bool(suspended) and not dry_run,
    }
    if dry_run or not suspended:
        yield payload
        return

    removed: list[dict[str, Any]] = []
    try:
        for name in suspended:
            registration = fetch_mcp_registration(name)
            remove_mcp_registration(name)
            removed.append(registration)
        yield payload
    finally:
        restore_errors: list[str] = []
        for registration in removed:
            try:
                restore_mcp_registration(registration)
            except Exception as exc:  # pragma: no cover - best effort restore
                restore_errors.append(str(exc))
        if restore_errors:
            print(
                "Warning: failed to restore some Codex MCP registrations: " + "; ".join(restore_errors),
                file=sys.stderr,
            )


def has_flag(arguments: list[str], *flags: str) -> bool:
    return any(arg in flags for arg in arguments)


def has_value_flag(arguments: list[str], *flags: str) -> bool:
    for arg in arguments:
        if arg in flags:
            return True
        for flag in flags:
            if arg.startswith(f"{flag}="):
                return True
    return False


def has_add_dir(arguments: list[str], candidate: Path) -> bool:
    resolved = candidate.resolve()
    for index, arg in enumerate(arguments):
        value = ""
        if arg == "--add-dir" and index + 1 < len(arguments):
            value = arguments[index + 1]
        elif arg.startswith("--add-dir="):
            value = arg.split("=", 1)[1]
        if not value:
            continue
        try:
            if Path(value).expanduser().resolve() == resolved:
                return True
        except OSError:
            continue
    return False


def looks_like_closeout_request(arguments: list[str]) -> bool:
    if not arguments:
        return False
    haystack = " ".join(arguments).lower()
    signals = (
        "qq-worktree.py",
        "closeout",
        "merge-back",
        "cleanup",
        "/qq:commit-push",
        "commit-push",
        "merge back",
        "merge_back",
        "push source",
    )
    return any(signal in haystack for signal in signals)


def build_exec_command(
    project_dir: Path,
    passthrough: list[str],
    *,
    allow_source_worktree: bool = False,
) -> dict[str, Any]:
    config = resolve_project_config(project_dir)
    trust_level = str(config.get("trust_level") or "trusted")
    trust_expectations = config.get("trust_level_expectations") or {}
    source_worktree_access = str(trust_expectations.get("codex_source_worktree_access") or "auto")
    worktree = load_worktree_status(project_dir)
    is_managed = bool(worktree.get("isManagedWorktree"))
    source_path_raw = str(worktree.get("sourceWorktreePath") or "")
    source_path = Path(source_path_raw).expanduser().resolve() if source_path_raw else None

    explicit_sandbox = (
        has_value_flag(passthrough, "--sandbox", "-s")
        or has_flag(passthrough, "--full-auto", "--dangerously-bypass-approvals-and-sandbox")
    )
    explicit_cd = has_value_flag(passthrough, "--cd", "-C")

    command = ["codex", "exec"]
    default_sandbox_applied = False
    default_cd_applied = False
    added_source_dir = False
    added_source_dir_reason = ""

    if not explicit_sandbox:
        command.extend(["--sandbox", "workspace-write"])
        default_sandbox_applied = True

    if not explicit_cd:
        command.extend(["-C", str(project_dir)])
        default_cd_applied = True

    if (
        is_managed
        and source_path
        and source_path.is_dir()
        and source_path != project_dir
        and not has_add_dir(passthrough, source_path)
    ):
        if allow_source_worktree:
            command.extend(["--add-dir", str(source_path)])
            added_source_dir = True
            added_source_dir_reason = "flag:allow_source_worktree"
        elif source_worktree_access == "auto":
            command.extend(["--add-dir", str(source_path)])
            added_source_dir = True
            added_source_dir_reason = "trust_level:auto"
        elif source_worktree_access == "closeout_only":
            if looks_like_closeout_request(passthrough):
                command.extend(["--add-dir", str(source_path)])
                added_source_dir = True
                added_source_dir_reason = "trust_level:closeout_only"
            else:
                added_source_dir_reason = "trust_level:closeout_only_blocked"
        else:
            added_source_dir_reason = "trust_level:explicit_required"

    command.extend(passthrough)
    payload = {
        "projectDir": str(project_dir),
        "trustLevel": trust_level,
        "trustLevelExpectations": trust_expectations,
        "isManagedWorktree": is_managed,
        "sourceWorktreePath": str(source_path) if source_path else "",
        "sourceWorktreeAccess": source_worktree_access,
        "defaultSandboxApplied": default_sandbox_applied,
        "defaultCdApplied": default_cd_applied,
        "addedSourceDir": added_source_dir,
        "addedSourceDirReason": added_source_dir_reason,
        "command": command,
    }
    with isolate_project_mcp_server(project_dir, dry_run=True) as isolation:
        payload["codexMcpIsolation"] = isolation
    return payload


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        allow_abbrev=False,
        description="Thin Codex exec wrapper for qq projects and managed worktrees",
    )
    parser.add_argument("--project", default=".", help="Project root used for qq context inspection")
    parser.add_argument("--dry-run", action="store_true", help="Print the resolved exec command instead of running Codex")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output for --dry-run")
    parser.add_argument("--allow-source-worktree", action="store_true", help="Explicitly widen Codex write scope to the source worktree when running from a managed worktree")
    return parser


def main() -> int:
    parser = build_parser()
    args, passthrough = parser.parse_known_args()
    if passthrough[:1] == ["--"]:
        passthrough = passthrough[1:]

    project_dir = resolve_project_dir(args.project)
    try:
        payload = build_exec_command(
            project_dir,
            passthrough,
            allow_source_worktree=args.allow_source_worktree,
        )
    except ConfigError as exc:
        print(f"qq-codex-exec: error: {exc}", file=sys.stderr)
        return 2

    if args.dry_run:
        payload["ok"] = True
        payload["action"] = "dry-run"
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
        sys.stdout.write("\n")
        return 0

    if shutil.which("codex") is None:
        print("Error: codex CLI not found. Install with: npm install -g @openai/codex", file=sys.stderr)
        return 1

    with isolate_project_mcp_server(project_dir) as isolation:
        payload["codexMcpIsolation"] = isolation
        return subprocess.run(payload["command"], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
