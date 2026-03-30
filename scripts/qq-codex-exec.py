#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent


def resolve_project_dir(value: str) -> Path:
    return Path(value).expanduser().resolve()


def load_worktree_status(project_dir: Path) -> dict[str, Any]:
    helper = SCRIPT_DIR / "qq-worktree.py"
    if not helper.is_file():
        return {}
    result = subprocess.run(
        ["python3", str(helper), "status", "--project", str(project_dir)],
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


def build_exec_command(project_dir: Path, passthrough: list[str]) -> dict[str, Any]:
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
        command.extend(["--add-dir", str(source_path)])
        added_source_dir = True

    command.extend(passthrough)
    return {
        "projectDir": str(project_dir),
        "isManagedWorktree": is_managed,
        "sourceWorktreePath": str(source_path) if source_path else "",
        "defaultSandboxApplied": default_sandbox_applied,
        "defaultCdApplied": default_cd_applied,
        "addedSourceDir": added_source_dir,
        "command": command,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        allow_abbrev=False,
        description="Thin Codex exec wrapper for qq projects and managed worktrees",
    )
    parser.add_argument("--project", default=".", help="Project root used for qq context inspection")
    parser.add_argument("--dry-run", action="store_true", help="Print the resolved exec command instead of running Codex")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output for --dry-run")
    return parser


def main() -> int:
    parser = build_parser()
    args, passthrough = parser.parse_known_args()
    if passthrough[:1] == ["--"]:
        passthrough = passthrough[1:]

    project_dir = resolve_project_dir(args.project)
    payload = build_exec_command(project_dir, passthrough)

    if args.dry_run:
        payload["ok"] = True
        payload["action"] = "dry-run"
        json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
        sys.stdout.write("\n")
        return 0

    if shutil.which("codex") is None:
        print("Error: codex CLI not found. Install with: npm install -g @openai/codex", file=sys.stderr)
        return 1

    return subprocess.run(payload["command"], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
