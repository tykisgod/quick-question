#!/usr/bin/env python3
"""Track bootstrap epic progress — deterministic state management for /qq:bootstrap."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

STATE_FILE = ".qq/state/bootstrap.json"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def load_state(project: Path) -> dict:
    path = project / STATE_FILE
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {}


def save_state(project: Path, state: dict) -> None:
    path = project / STATE_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")


def cmd_init(args: argparse.Namespace) -> dict:
    """Initialize bootstrap state from a manifest."""
    project = Path(args.project).resolve()
    epics = []
    for i, name in enumerate(args.epics):
        epics.append({
            "id": i + 1,
            "name": name,
            "status": "pending",  # pending | running | paused | completed | skipped
            "retries": 0,
            "maxRetries": args.max_retries,
            "dependsOn": [],
            "parallel": False,
            "startedAt": "",
            "completedAt": "",
            "pauseReason": "",
            "worktree": "",
        })
    state = {
        "version": 1,
        "projectName": args.name,
        "manifestPath": args.manifest,
        "createdAt": utc_now(),
        "updatedAt": utc_now(),
        "status": "running",  # running | paused | completed
        "currentEpicId": 0,
        "epics": epics,
    }
    save_state(project, state)
    return {"ok": True, "action": "init", "epicCount": len(epics)}


def cmd_start_epic(args: argparse.Namespace) -> dict:
    """Mark an epic as running."""
    project = Path(args.project).resolve()
    state = load_state(project)
    if not state:
        return {"ok": False, "error": "No bootstrap state found. Run init first."}
    epic = next((e for e in state["epics"] if e["id"] == args.epic_id), None)
    if not epic:
        return {"ok": False, "error": f"Epic {args.epic_id} not found"}
    # Check dependencies
    for dep_id in epic.get("dependsOn", []):
        dep = next((e for e in state["epics"] if e["id"] == dep_id), None)
        if dep and dep["status"] != "completed":
            return {"ok": False, "error": f"Dependency epic {dep_id} ({dep['name']}) not completed yet"}
    epic["status"] = "running"
    epic["startedAt"] = utc_now()
    epic["retries"] = 0
    if args.worktree:
        epic["worktree"] = args.worktree
    state["currentEpicId"] = args.epic_id
    state["updatedAt"] = utc_now()
    save_state(project, state)
    return {"ok": True, "action": "start-epic", "epicId": args.epic_id, "name": epic["name"]}


def cmd_complete_epic(args: argparse.Namespace) -> dict:
    """Mark an epic as completed."""
    project = Path(args.project).resolve()
    state = load_state(project)
    if not state:
        return {"ok": False, "error": "No bootstrap state found"}
    epic = next((e for e in state["epics"] if e["id"] == args.epic_id), None)
    if not epic:
        return {"ok": False, "error": f"Epic {args.epic_id} not found"}
    epic["status"] = "completed"
    epic["completedAt"] = utc_now()
    state["updatedAt"] = utc_now()
    # Check if all epics done
    if all(e["status"] in ("completed", "skipped") for e in state["epics"]):
        state["status"] = "completed"
    save_state(project, state)
    return {"ok": True, "action": "complete-epic", "epicId": args.epic_id, "name": epic["name"]}


def cmd_fail_epic(args: argparse.Namespace) -> dict:
    """Record a failure. Pause after max retries."""
    project = Path(args.project).resolve()
    state = load_state(project)
    if not state:
        return {"ok": False, "error": "No bootstrap state found"}
    epic = next((e for e in state["epics"] if e["id"] == args.epic_id), None)
    if not epic:
        return {"ok": False, "error": f"Epic {args.epic_id} not found"}
    epic["retries"] += 1
    if epic["retries"] >= epic["maxRetries"]:
        epic["status"] = "paused"
        epic["pauseReason"] = args.reason or f"Failed {epic['maxRetries']} times"
        state["updatedAt"] = utc_now()
        save_state(project, state)
        return {"ok": True, "action": "paused", "epicId": args.epic_id, "retries": epic["retries"], "reason": epic["pauseReason"]}
    state["updatedAt"] = utc_now()
    save_state(project, state)
    return {"ok": True, "action": "retry", "epicId": args.epic_id, "retries": epic["retries"], "maxRetries": epic["maxRetries"]}


def cmd_status(args: argparse.Namespace) -> dict:
    """Get current bootstrap progress."""
    project = Path(args.project).resolve()
    state = load_state(project)
    if not state:
        return {"ok": False, "error": "No bootstrap state found"}
    completed = sum(1 for e in state["epics"] if e["status"] == "completed")
    paused = sum(1 for e in state["epics"] if e["status"] == "paused")
    running = sum(1 for e in state["epics"] if e["status"] == "running")
    pending = sum(1 for e in state["epics"] if e["status"] == "pending")
    # Find next actionable epics (pending + all deps completed)
    actionable = []
    for e in state["epics"]:
        if e["status"] != "pending":
            continue
        deps_met = all(
            next((d for d in state["epics"] if d["id"] == dep_id), {}).get("status") == "completed"
            for dep_id in e.get("dependsOn", [])
        )
        if deps_met:
            actionable.append({"id": e["id"], "name": e["name"], "parallel": e.get("parallel", False)})
    return {
        "ok": True,
        "action": "status",
        "projectName": state["projectName"],
        "status": state["status"],
        "total": len(state["epics"]),
        "completed": completed,
        "running": running,
        "paused": paused,
        "pending": pending,
        "actionableEpics": actionable,
        "epics": [{"id": e["id"], "name": e["name"], "status": e["status"], "retries": e["retries"]} for e in state["epics"]],
    }


def cmd_set_deps(args: argparse.Namespace) -> dict:
    """Set dependencies and parallel flags for an epic."""
    project = Path(args.project).resolve()
    state = load_state(project)
    if not state:
        return {"ok": False, "error": "No bootstrap state found"}
    epic = next((e for e in state["epics"] if e["id"] == args.epic_id), None)
    if not epic:
        return {"ok": False, "error": f"Epic {args.epic_id} not found"}
    if args.depends_on is not None:
        epic["dependsOn"] = [int(x) for x in args.depends_on.split(",") if x.strip()]
    if args.parallel is not None:
        epic["parallel"] = args.parallel
    state["updatedAt"] = utc_now()
    save_state(project, state)
    return {"ok": True, "action": "set-deps", "epicId": args.epic_id}


def cmd_clear(args: argparse.Namespace) -> dict:
    """Remove bootstrap state."""
    project = Path(args.project).resolve()
    path = project / STATE_FILE
    if path.exists():
        path.unlink()
    return {"ok": True, "action": "clear"}


def main() -> None:
    parser = argparse.ArgumentParser(description="Bootstrap epic state management")
    parser.add_argument("--pretty", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init")
    init.add_argument("--project", default=".")
    init.add_argument("--name", required=True, help="Project name")
    init.add_argument("--manifest", default="", help="Path to manifest file")
    init.add_argument("--epics", nargs="+", required=True, help="Epic names in order")
    init.add_argument("--max-retries", type=int, default=3)

    start = sub.add_parser("start-epic")
    start.add_argument("--project", default=".")
    start.add_argument("--epic-id", type=int, required=True)
    start.add_argument("--worktree", default="")

    complete = sub.add_parser("complete-epic")
    complete.add_argument("--project", default=".")
    complete.add_argument("--epic-id", type=int, required=True)

    fail = sub.add_parser("fail-epic")
    fail.add_argument("--project", default=".")
    fail.add_argument("--epic-id", type=int, required=True)
    fail.add_argument("--reason", default="")

    status = sub.add_parser("status")
    status.add_argument("--project", default=".")

    deps = sub.add_parser("set-deps")
    deps.add_argument("--project", default=".")
    deps.add_argument("--epic-id", type=int, required=True)
    deps.add_argument("--depends-on", default=None, help="Comma-separated epic IDs")
    deps.add_argument("--parallel", type=bool, default=None)

    clear = sub.add_parser("clear")
    clear.add_argument("--project", default=".")

    args = parser.parse_args()
    handlers = {
        "init": cmd_init,
        "start-epic": cmd_start_epic,
        "complete-epic": cmd_complete_epic,
        "fail-epic": cmd_fail_epic,
        "status": cmd_status,
        "set-deps": cmd_set_deps,
        "clear": cmd_clear,
    }

    try:
        result = handlers[args.command](args)
    except Exception as exc:
        result = {"ok": False, "error": str(exc)}

    indent = 2 if args.pretty else None
    print(json.dumps(result, indent=indent, ensure_ascii=False))
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
