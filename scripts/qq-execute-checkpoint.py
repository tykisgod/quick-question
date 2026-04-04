#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_timestamp(value: datetime | None = None) -> str:
    return (value or utc_now()).isoformat(timespec="microseconds").replace("+00:00", "Z")


def progress_path(project_dir: Path) -> Path:
    state = project_dir / ".qq" / "state"
    state.mkdir(parents=True, exist_ok=True)
    return state / "execute-progress.json"


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def save_json(path: Path, value: dict[str, Any]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


def update_plan_checkbox(plan_path: Path, step: int, step_title: str) -> bool:
    if not plan_path.is_file() or step < 1:
        return False
    text = plan_path.read_text(encoding="utf-8")

    if step_title:
        escaped = re.escape(step_title)
        pattern = rf"^(\s*- )\[ \](\s.*{escaped})"
        updated, count = re.subn(pattern, r"\1[x]\2", text, count=1, flags=re.MULTILINE)
        if count > 0:
            plan_path.write_text(updated, encoding="utf-8")
            return True

    checkbox_pattern = re.compile(r"^(\s*- )\[ \](\s)", re.MULTILINE)
    matches = list(checkbox_pattern.finditer(text))
    if step <= len(matches):
        match = matches[step - 1]
        updated = text[:match.start()] + match.group(1) + "[x]" + match.group(2) + text[match.end():]
        plan_path.write_text(updated, encoding="utf-8")
        return True
    return False


def command_save(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    path = progress_path(project_dir)
    progress = load_json(path)

    completed_steps: list[int] = list(progress.get("completed_steps") or [])
    step = int(args.step)
    if step > 0 and step not in completed_steps:
        completed_steps.append(step)
        completed_steps.sort()

    progress.update({
        "version": 1,
        "plan_path": args.plan,
        "mode": args.mode,
        "total_steps": int(args.total),
        "completed_step": max(completed_steps) if completed_steps else 0,
        "completed_steps": completed_steps,
        "current_phase": args.phase or progress.get("current_phase") or "",
        "status": args.status,
        "updated_at": iso_timestamp(),
    })
    if "started_at" not in progress:
        progress["started_at"] = iso_timestamp()

    save_json(path, progress)

    if step > 0:
        plan_file = Path(args.plan)
        if not plan_file.is_absolute():
            plan_file = project_dir / plan_file
        update_plan_checkbox(plan_file, step, args.step_title or "")

    result = {"ok": True, "step": step, "completed_steps": completed_steps, "status": args.status}
    print(json.dumps(result, ensure_ascii=False))
    return 0


def command_resume(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    progress = load_json(progress_path(project_dir))

    if not progress or progress.get("status") not in ("running", "paused"):
        print("{}")
        return 0

    if args.format == "hint":
        completed = progress.get("completed_step", 0)
        total = progress.get("total_steps", 0)
        plan = progress.get("plan_path", "")
        mode = progress.get("mode", "")
        phase = progress.get("current_phase", "")
        lines = [
            f"[qq-execute] Active execution detected.",
            f"Plan: {plan}",
            f"Mode: {mode}",
            f"Progress: {completed}/{total} steps completed",
        ]
        if phase:
            lines.append(f"Current phase: {phase}")
        lines.append(f"Run /qq:execute {plan} to resume.")
        print("\n".join(lines))
    else:
        print(json.dumps(progress, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=True))
    return 0


def command_clear(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    path = progress_path(project_dir)
    progress = load_json(path)

    if not progress:
        print(json.dumps({"ok": True, "status": "no_progress"}))
        return 0

    progress["status"] = args.status
    progress["updated_at"] = iso_timestamp()
    save_json(path, progress)

    print(json.dumps({"ok": True, "status": args.status}))
    return 0


PIPELINE_FILE = "auto-pipeline.json"


def pipeline_path(project_dir: Path) -> Path:
    state = project_dir / ".qq" / "state"
    state.mkdir(parents=True, exist_ok=True)
    return state / PIPELINE_FILE


def command_pipeline_start(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    path = pipeline_path(project_dir)
    state = {
        "version": 1,
        "pipeline_type": args.type,
        "current_skill": args.current_skill,
        "completed_skills": [],
        "context": {
            "design_doc": "",
            "plan_doc": "",
            "branch": args.branch or "",
        },
        "status": "running",
        "iteration_count": 0,
        "max_iterations": int(args.max_iterations),
        "last_blocked_skill": "",
        "same_skill_block_count": 0,
        "started_at": iso_timestamp(),
        "updated_at": iso_timestamp(),
    }
    save_json(path, state)
    print(json.dumps({"ok": True, "action": "pipeline-start", "current_skill": args.current_skill}))
    return 0


def command_pipeline_advance(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    path = pipeline_path(project_dir)
    state = load_json(path)
    if not state or state.get("status") != "running":
        print(json.dumps({"ok": False, "error": "No running pipeline"}))
        return 1
    completed = list(state.get("completed_skills") or [])
    if args.completed_skill and args.completed_skill not in completed:
        completed.append(args.completed_skill)
    state["completed_skills"] = completed
    state["current_skill"] = args.next_skill or ""
    if args.design_doc:
        state["context"]["design_doc"] = args.design_doc
    if args.plan_doc:
        state["context"]["plan_doc"] = args.plan_doc
    state["updated_at"] = iso_timestamp()
    save_json(path, state)
    print(json.dumps({"ok": True, "action": "pipeline-advance", "completed_skill": args.completed_skill, "next_skill": args.next_skill}))
    return 0


def command_pipeline_status(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    state = load_json(pipeline_path(project_dir))
    if not state:
        print("{}")
        return 0
    if args.format == "hint":
        if state.get("status") != "running":
            return 0
        current = state.get("current_skill", "")
        completed = state.get("completed_skills", [])
        iteration = state.get("iteration_count", 0)
        max_iter = state.get("max_iterations", 20)
        ctx = state.get("context", {})
        lines = [
            f"[auto-pipeline] Active --auto pipeline ({state.get('pipeline_type', '?')}, iteration {iteration}/{max_iter}).",
            f"Completed: {' -> '.join(completed) if completed else 'none'}",
            f"Next: {current}",
        ]
        if ctx.get("plan_doc"):
            lines.append(f"Artifact: {ctx['plan_doc']}")
        elif ctx.get("design_doc"):
            lines.append(f"Artifact: {ctx['design_doc']}")
        lines.append(f"You MUST continue by invoking {current} --auto. Do not ask the user.")
        print("\n".join(lines))
    else:
        print(json.dumps(state, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=True))
    return 0


def command_pipeline_clear(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    path = pipeline_path(project_dir)
    state = load_json(path)
    if not state:
        print(json.dumps({"ok": True, "status": "no_pipeline"}))
        return 0
    state["status"] = args.status
    state["updated_at"] = iso_timestamp()
    save_json(path, state)
    print(json.dumps({"ok": True, "status": args.status}))
    return 0


def command_pipeline_block(args: argparse.Namespace) -> int:
    """Called by the Stop hook to record a block event and check circuit breakers."""
    project_dir = Path(args.project).resolve()
    path = pipeline_path(project_dir)
    state = load_json(path)
    if not state or state.get("status") != "running":
        print(json.dumps({"action": "allow", "reason": "no running pipeline"}))
        return 0

    iteration = state.get("iteration_count", 0)
    max_iter = state.get("max_iterations", 20)

    # Circuit breaker: max iterations
    if iteration >= max_iter:
        state["status"] = "abandoned"
        state["updated_at"] = iso_timestamp()
        save_json(path, state)
        print(json.dumps({"action": "allow", "reason": f"exceeded max iterations ({max_iter})"}))
        return 0

    # Circuit breaker: same skill blocked 3 times
    current = state.get("current_skill", "")
    last_blocked = state.get("last_blocked_skill", "")
    if current == last_blocked:
        state["same_skill_block_count"] = state.get("same_skill_block_count", 0) + 1
        if state["same_skill_block_count"] >= 3:
            state["status"] = "abandoned"
            state["updated_at"] = iso_timestamp()
            save_json(path, state)
            print(json.dumps({"action": "allow", "reason": f"stuck on {current} for 3 blocks"}))
            return 0
    else:
        state["last_blocked_skill"] = current
        state["same_skill_block_count"] = 1

    # Circuit breaker: time limit (4 hours)
    started = state.get("started_at", "")
    if started:
        try:
            started_dt = datetime.fromisoformat(started.replace("Z", "+00:00"))
            if (utc_now() - started_dt).total_seconds() > 14400:
                state["status"] = "abandoned"
                state["updated_at"] = iso_timestamp()
                save_json(path, state)
                print(json.dumps({"action": "allow", "reason": "exceeded 4 hour time limit"}))
                return 0
        except Exception:
            pass

    # Block exit
    state["iteration_count"] = iteration + 1
    state["updated_at"] = iso_timestamp()
    save_json(path, state)

    completed = state.get("completed_skills", [])
    ctx = state.get("context", {})
    artifact = ctx.get("plan_doc") or ctx.get("design_doc") or ""
    resume_cmd = f"{current} --auto"
    if artifact:
        resume_cmd += f" {artifact}"

    print(json.dumps({
        "action": "block",
        "current_skill": current,
        "completed_skills": completed,
        "iteration": iteration + 1,
        "max_iterations": max_iter,
        "resume_command": resume_cmd,
    }))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="qq execute checkpoint helper")
    subparsers = parser.add_subparsers(dest="command_name", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", default=".", help="Project root")

    save = subparsers.add_parser("save", parents=[common], help="Save execution progress")
    save.add_argument("--plan", required=True, help="Plan file path")
    save.add_argument("--step", type=int, required=True, help="Step number just completed (0 for init)")
    save.add_argument("--total", type=int, required=True, help="Total number of steps")
    save.add_argument("--mode", required=True, choices=["coordinator", "direct"], help="Execution mode")
    save.add_argument("--phase", default="", help="Current phase name")
    save.add_argument("--step-title", default="", help="Step title text for checkbox matching")
    save.add_argument("--status", default="running", choices=["running", "paused", "failed"])
    save.set_defaults(func=command_save)

    resume = subparsers.add_parser("resume", parents=[common], help="Check for interrupted execution")
    resume.add_argument("--format", default="json", choices=["json", "hint"], help="Output format")
    resume.add_argument("--pretty", action="store_true")
    resume.set_defaults(func=command_resume)

    clear = subparsers.add_parser("clear", parents=[common], help="Mark execution complete or cancelled")
    clear.add_argument("--status", default="completed", choices=["completed", "cancelled"])
    clear.set_defaults(func=command_clear)

    # Pipeline-level commands (auto-pipeline state management)
    p_start = subparsers.add_parser("pipeline-start", parents=[common], help="Start auto-pipeline tracking")
    p_start.add_argument("--type", default="feature", choices=["feature", "bootstrap", "single-skill"])
    p_start.add_argument("--current-skill", required=True, help="First skill in the pipeline")
    p_start.add_argument("--branch", default="", help="Current branch name")
    p_start.add_argument("--max-iterations", type=int, default=20)
    p_start.set_defaults(func=command_pipeline_start)

    p_advance = subparsers.add_parser("pipeline-advance", parents=[common], help="Mark a pipeline skill as completed")
    p_advance.add_argument("--completed-skill", required=True)
    p_advance.add_argument("--next-skill", default="")
    p_advance.add_argument("--design-doc", default="")
    p_advance.add_argument("--plan-doc", default="")
    p_advance.set_defaults(func=command_pipeline_advance)

    p_status = subparsers.add_parser("pipeline-status", parents=[common], help="Check pipeline state")
    p_status.add_argument("--format", default="json", choices=["json", "hint"])
    p_status.add_argument("--pretty", action="store_true")
    p_status.set_defaults(func=command_pipeline_status)

    p_clear = subparsers.add_parser("pipeline-clear", parents=[common], help="Mark pipeline complete or abandoned")
    p_clear.add_argument("--status", default="completed", choices=["completed", "abandoned"])
    p_clear.set_defaults(func=command_pipeline_clear)

    p_block = subparsers.add_parser("pipeline-block", parents=[common], help="Record a Stop hook block event (used by hooks)")
    p_block.set_defaults(func=command_pipeline_block)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return args.func(args)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
