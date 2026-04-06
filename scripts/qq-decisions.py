#!/usr/bin/env python3
"""qq-decisions.py — Track design/plan/execute decisions across skills.

Decisions are accumulated in .qq/state/session-decisions.json so that
downstream skills know WHY upstream skills made certain choices.

Usage:
    qq-decisions.py add --project . --phase design --key "core_mechanic" --value "turn-based" --reason "user preference"
    qq-decisions.py list --project . [--phase design]
    qq-decisions.py summary --project . [--max 10]
    qq-decisions.py clear --project .
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


DECISIONS_FILE = "session-decisions.json"


def decisions_path(project_dir: Path) -> Path:
    state = project_dir / ".qq" / "state"
    state.mkdir(parents=True, exist_ok=True)
    return state / DECISIONS_FILE


def load_decisions(project_dir: Path) -> list[dict]:
    path = decisions_path(project_dir)
    if not path.exists():
        return []
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return []


def save_decisions(project_dir: Path, decisions: list[dict]) -> None:
    path = decisions_path(project_dir)
    path.write_text(json.dumps(decisions, indent=2))


def command_add(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    decisions = load_decisions(project_dir)
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "phase": args.phase,
        "key": args.key,
        "value": args.value,
        "reason": args.reason or "",
    }
    decisions.append(entry)
    save_decisions(project_dir, decisions)
    print(json.dumps({"ok": True, "action": "add", "entry": entry}))
    return 0


def command_list(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    decisions = load_decisions(project_dir)
    if args.phase:
        decisions = [d for d in decisions if d.get("phase") == args.phase]
    print(json.dumps(decisions, indent=2))
    return 0


def command_summary(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    decisions = load_decisions(project_dir)
    max_items = args.max or 20
    recent = decisions[-max_items:]
    lines = []
    for d in recent:
        phase = d.get("phase", "?")
        key = d.get("key", "?")
        value = d.get("value", "?")
        reason = d.get("reason", "")
        line = f"[{phase}] {key}: {value}"
        if reason:
            line += f" (reason: {reason})"
        lines.append(line)
    print("\n".join(lines) if lines else "(no decisions recorded)")
    return 0


def command_clear(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    save_decisions(project_dir, [])
    print(json.dumps({"ok": True, "action": "clear"}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Track cross-skill decisions")
    subparsers = parser.add_subparsers(dest="command")

    add_p = subparsers.add_parser("add", help="Add a decision")
    add_p.add_argument("--project", default=".", help="Project root")
    add_p.add_argument("--phase", required=True, help="Phase: design|plan|execute|review")
    add_p.add_argument("--key", required=True, help="Decision key")
    add_p.add_argument("--value", required=True, help="Decision value")
    add_p.add_argument("--reason", default="", help="Why this decision was made")

    list_p = subparsers.add_parser("list", help="List decisions")
    list_p.add_argument("--project", default=".", help="Project root")
    list_p.add_argument("--phase", default="", help="Filter by phase")

    summary_p = subparsers.add_parser("summary", help="Human-readable summary")
    summary_p.add_argument("--project", default=".", help="Project root")
    summary_p.add_argument("--max", type=int, default=20, help="Max entries")

    clear_p = subparsers.add_parser("clear", help="Clear all decisions")
    clear_p.add_argument("--project", default=".", help="Project root")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return 1

    commands = {"add": command_add, "list": command_list, "summary": command_summary, "clear": command_clear}
    return commands[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
