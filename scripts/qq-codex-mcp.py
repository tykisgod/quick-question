#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from qq_engine import bridge_script, codex_server_prefix, default_slug, resolve_project_engine


def resolve_project_dir(value: str) -> Path:
    project_dir = Path(value).expanduser().resolve()
    if not resolve_project_engine(project_dir):
        raise SystemExit(f"Error: {project_dir} is not a supported engine project")
    return project_dir


def slugify(value: str, engine: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or default_slug(engine)


def default_server_name(project_dir: Path, engine: str) -> str:
    digest = hashlib.sha1(str(project_dir).encode("utf-8")).hexdigest()[:8]
    return f"{codex_server_prefix(engine)}{slugify(project_dir.name, engine)}-{digest}"


def expected_transport(project_dir: Path, engine: str, profile: str) -> dict[str, Any]:
    bridge_name = bridge_script(engine)
    args = [
        str((project_dir / "scripts" / bridge_name).resolve()),
        "--project",
        str(project_dir.resolve()),
    ]
    if profile != "standard":
        args.extend(["--profile", "full"])
    return {
        "type": "stdio",
        "command": "python3",
        "args": args,
        "cwd": None,
    }


def bridge_path(project_dir: Path, engine: str) -> Path:
    return project_dir / "scripts" / bridge_script(engine)


def run_codex(arguments: list[str], check: bool) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["codex", "mcp", *arguments],
        check=check,
        capture_output=True,
        text=True,
    )


def fetch_registration(name: str) -> dict[str, Any] | None:
    result = run_codex(["get", name, "--json"], check=False)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        if "No MCP server named" in message:
            return None
        raise RuntimeError(message or f"codex mcp get {name} failed")
    return json.loads(result.stdout)


def status_payload(project_dir: Path, engine: str, name: str, profile: str) -> dict[str, Any]:
    bridge = bridge_path(project_dir, engine)
    payload: dict[str, Any] = {
        "projectDir": str(project_dir),
        "engine": engine,
        "serverName": name,
        "profile": profile,
        "codexInstalled": shutil.which("codex") is not None,
        "bridgePath": str(bridge),
        "bridgeExists": bridge.is_file(),
        "expected": expected_transport(project_dir, engine, profile),
        "registered": False,
        "matchesExpected": False,
        "state": "",
        "action": "",
        "actual": {},
    }
    if not payload["codexInstalled"]:
        payload["state"] = "codex_missing"
        payload["action"] = "install_codex_cli"
        return payload
    if not payload["bridgeExists"]:
        payload["state"] = "bridge_missing"
        payload["action"] = "run_install_sh"
        return payload

    current = fetch_registration(name)
    if current is None:
        payload["state"] = "missing"
        payload["action"] = "install"
        return payload

    payload["registered"] = True
    actual = current.get("transport") or {}
    payload["actual"] = actual
    expected = payload["expected"]
    matches = (
        isinstance(actual, dict)
        and actual.get("type") == expected["type"]
        and actual.get("command") == expected["command"]
        and list(actual.get("args") or []) == expected["args"]
    )
    payload["matchesExpected"] = matches
    payload["state"] = "configured" if matches else "misconfigured"
    payload["action"] = "none" if matches else "reinstall"
    return payload


def add_registration(name: str, project_dir: Path, engine: str, profile: str) -> None:
    transport = expected_transport(project_dir, engine, profile)
    run_codex(
        [
            "add",
            name,
            "--",
            transport["command"],
            *transport["args"],
        ],
        check=True,
    )


def remove_registration(name: str) -> bool:
    result = run_codex(["remove", name], check=False)
    if result.returncode == 0:
        return True
    message = (result.stderr or result.stdout).strip()
    if "No MCP server named" in message:
        return False
    raise RuntimeError(message or f"codex mcp remove {name} failed")


def install_action(project_dir: Path, engine: str, name: str, profile: str) -> tuple[dict[str, Any], int]:
    payload = status_payload(project_dir, engine, name, profile)
    if payload["state"] in {"codex_missing", "bridge_missing"}:
        return payload, 1
    if payload["registered"] and payload["matchesExpected"]:
        payload["changed"] = False
        return payload, 0
    if payload["registered"] and not payload["matchesExpected"]:
        remove_registration(name)
    add_registration(name, project_dir, engine, profile)
    updated = status_payload(project_dir, engine, name, profile)
    updated["changed"] = True
    return updated, 0


def remove_action(project_dir: Path, engine: str, name: str, profile: str) -> tuple[dict[str, Any], int]:
    payload = status_payload(project_dir, engine, name, profile)
    if payload["state"] == "codex_missing":
        payload["changed"] = False
        return payload, 1
    changed = remove_registration(name)
    payload = status_payload(project_dir, engine, name, profile)
    payload["changed"] = changed
    return payload, 0


def parse_args() -> argparse.Namespace:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", default=".", help="Supported engine project root")
    common.add_argument("--name", help="Codex MCP server name (defaults to a project-specific qq name)")
    common.add_argument("--profile", default="standard", choices=["standard", "full"], help="Bridge tool profile")
    common.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    parser = argparse.ArgumentParser(
        description="Register or inspect the built-in project-local qq bridge in Codex CLI",
        parents=[common],
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status", parents=[common], help="Inspect current Codex MCP registration for this project")
    subparsers.add_parser("install", parents=[common], help="Ensure Codex CLI is registered to this project's built-in bridge")
    subparsers.add_parser("remove", parents=[common], help="Remove this project's Codex MCP registration")
    subparsers.add_parser("name", parents=[common], help="Print the default server name for this project")
    return parser.parse_args()


def emit(payload: dict[str, Any], pretty: bool) -> None:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if pretty else None, sort_keys=pretty)
    sys.stdout.write("\n")


def main() -> int:
    args = parse_args()
    project_dir = resolve_project_dir(args.project)
    engine = resolve_project_engine(project_dir)
    name = args.name or default_server_name(project_dir, engine)

    if args.command == "name":
        emit(
            {
                "projectDir": str(project_dir),
                "engine": engine,
                "serverName": name,
            },
            args.pretty,
        )
        return 0
    if args.command == "status":
        emit(status_payload(project_dir, engine, name, args.profile), args.pretty)
        return 0
    if args.command == "install":
        payload, code = install_action(project_dir, engine, name, args.profile)
        emit(payload, args.pretty)
        return code
    payload, code = remove_action(project_dir, engine, name, args.profile)
    emit(payload, args.pretty)
    return code


if __name__ == "__main__":
    sys.exit(main())
