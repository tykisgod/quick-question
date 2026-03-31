#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from qq_internal_config import DEFAULT_CONTEXT_CAPSULE, resolve_project_config


SCRIPT_DIR = Path(__file__).resolve().parent
VALID_TRIGGERS = {
    "manual",
    "resume",
    "pre_clear",
    "worktree_handoff",
    "after_blocker",
}
CONTINUATION_TRIGGERS = {"after_blocker", "pre_clear", "worktree_handoff", "resume"}


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_timestamp(value: datetime | None = None) -> str:
    return (value or utc_now()).isoformat(timespec="seconds").replace("+00:00", "Z")


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"Expected object in {path}")
    return value


def load_optional_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        return load_json(path)
    except Exception:
        return {}


def resolve_config(project_dir: Path) -> dict[str, Any]:
    payload = resolve_project_config(project_dir)
    config = payload.get("context_capsule") or {}
    if not isinstance(config, dict):
        config = {}
    merged = dict(DEFAULT_CONTEXT_CAPSULE)
    merged.update(config)
    return {
        "enabled": bool(merged.get("enabled", True)),
        "mode": str(merged.get("mode") or DEFAULT_CONTEXT_CAPSULE["mode"]),
        "triggers": list(merged.get("triggers") or DEFAULT_CONTEXT_CAPSULE["triggers"]),
        "maxChars": int(merged.get("max_chars") or DEFAULT_CONTEXT_CAPSULE["max_chars"]),
        "sharedSource": str(payload.get("shared_config_path") or "") if payload.get("shared_config_exists") else "",
        "localSource": str(payload.get("local_config_path") or "") if payload.get("local_config_exists") else "",
    }


def should_auto_build(config: dict[str, Any], trigger: str) -> bool:
    return bool(
        config.get("enabled")
        and config.get("mode") == "auto"
        and trigger in (config.get("triggers") or [])
    )


def runtime_dirs(project_dir: Path) -> dict[str, Path]:
    root = project_dir / ".qq"
    state = root / "state"
    telemetry = root / "telemetry"
    capsules = telemetry / "context-capsules"
    for path in (state, telemetry, capsules):
        path.mkdir(parents=True, exist_ok=True)
    return {
        "root": root,
        "state": state,
        "telemetry": telemetry,
        "capsules": capsules,
    }


def latest_project_state(project_dir: Path) -> dict[str, Any]:
    helper = SCRIPT_DIR / "qq-project-state.py"
    if helper.is_file():
        result = subprocess.run(
            ["python3", str(helper), "--project", str(project_dir), "--no-write"],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            try:
                payload = json.loads(result.stdout)
            except json.JSONDecodeError:
                payload = {}
            if isinstance(payload, dict):
                return payload
    return load_optional_json(project_dir / ".qq" / "state" / "project-state.json")


def latest_stage_record(project_dir: Path, stage: str) -> dict[str, Any]:
    state_path = project_dir / ".qq" / "state" / f"{stage}.json"
    payload = load_optional_json(state_path)
    if payload:
        return payload
    runs_dir = project_dir / ".qq" / "runs"
    if not runs_dir.is_dir():
        return {}
    for path in sorted(runs_dir.glob("*.json"), reverse=True):
        record = load_optional_json(path)
        if record.get("stage") == stage:
            return record
    return {}


def stage_evidence(record: dict[str, Any], fallback_status: str = "not_run") -> dict[str, Any]:
    return {
        "status": str(record.get("status") or fallback_status),
        "summary": str(record.get("summary") or ""),
        "failureCategory": str(record.get("failure_category") or ""),
        "finishedAt": str(record.get("finished_at") or record.get("started_at") or ""),
        "recordPath": str(record.get("record_path") or ""),
    }


def detect_objective(state: dict[str, Any]) -> str:
    task_focus = state.get("task_focus") or []
    if isinstance(task_focus, list) and task_focus:
        return f"Advance focus: {', '.join(str(item) for item in task_focus[:3])}"
    changed_files = state.get("changed_runtime_files") or []
    if isinstance(changed_files, list) and changed_files:
        return f"Continue current {state.get('work_mode') or 'feature'} task touching {len(changed_files)} runtime file(s)"
    return f"Continue current {state.get('work_mode') or 'feature'} task"


def build_blockers(state: dict[str, Any], evidence: dict[str, Any]) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []

    compile_state = str(state.get("last_compile_status") or "")
    if compile_state in {"failed", "blocked"}:
        blockers.append(
            {
                "kind": "compile",
                "status": compile_state,
                "summary": str(evidence["compile"].get("summary") or state.get("last_compile_summary") or ""),
                "failureCategory": str(
                    evidence["compile"].get("failureCategory") or state.get("last_compile_failure_category") or ""
                ),
            }
        )

    test_state = str(state.get("last_test_status") or "")
    if test_state in {"failed", "blocked"}:
        blockers.append(
            {
                "kind": "test",
                "status": test_state,
                "summary": str(evidence["test"].get("summary") or state.get("last_test_summary") or ""),
                "failureCategory": str(
                    evidence["test"].get("failureCategory") or state.get("last_test_failure_category") or ""
                ),
            }
        )

    return blockers


def line_join(values: list[str]) -> str:
    return ", ".join(value for value in values if value)


def trim_markdown(lines: list[str], max_chars: int) -> str:
    if max_chars <= 0:
        return ""

    output: list[str] = []
    current_length = 0
    trimmed = False
    for line in lines:
        addition = line if not output else f"\n{line}"
        if current_length + len(addition) > max_chars:
            trimmed = True
            break
        output.append(line)
        current_length += len(addition)

    if trimmed:
        suffix = "\n- Note: capsule trimmed to fit limit."
        text = "\n".join(output)
        if len(text) + len(suffix) <= max_chars:
            return text + suffix
        return text[: max(0, max_chars - 3)].rstrip() + "..."
    return "\n".join(output)


def build_resume_prompt(payload: dict[str, Any], max_chars: int) -> str:
    worktree = payload.get("worktree") or {}
    evidence = payload.get("evidence") or {}
    blockers = payload.get("blockers") or []
    lines = [
        "# Resume Capsule",
        f"- Objective: {payload.get('objective') or ''}",
        f"- Trigger: {payload.get('trigger') or ''}",
        f"- Work mode: {payload.get('workMode') or ''}",
        f"- Policy profile: {payload.get('policyProfile') or ''}",
        f"- Recommended next: {payload.get('recommendedNext') or ''}",
    ]

    changed_files = payload.get("changedFiles") or []
    if isinstance(changed_files, list) and changed_files:
        lines.append(f"- Changed runtime files: {line_join([str(item) for item in changed_files[:8]])}")

    active = payload.get("activeArtifacts") or {}
    design_docs = active.get("designDocs") or []
    implementation_plans = active.get("implementationPlans") or []
    if design_docs:
        lines.append(f"- Active design docs: {line_join([str(item) for item in design_docs[:4]])}")
    if implementation_plans:
        lines.append(f"- Active implementation plans: {line_join([str(item) for item in implementation_plans[:4]])}")

    lines.extend(
        [
            f"- Compile: {evidence.get('compile', {}).get('status', 'not_run')} ({evidence.get('compile', {}).get('summary', '')})",
            f"- Test: {evidence.get('test', {}).get('status', 'not_run')} ({evidence.get('test', {}).get('summary', '')})",
            f"- Review gate: {evidence.get('reviewGate', {}).get('status', 'not_started')}",
            f"- Doc drift: {evidence.get('docDrift', {}).get('status', 'not_checked')}",
        ]
    )

    if blockers:
        lines.append("- Blockers:")
        for blocker in blockers[:4]:
            summary = str(blocker.get("summary") or blocker.get("failureCategory") or blocker.get("status") or "")
            lines.append(f"  - {blocker.get('kind')}: {summary}")
    else:
        lines.append("- Blockers: none")

    if worktree.get("isManagedWorktree"):
        lines.append(f"- Worktree: managed ({worktree.get('branch') or ''} <- {worktree.get('sourceBranch') or ''})")
    else:
        lines.append("- Worktree: primary")

    lines.append("- Use this capsule as a thin handoff. Treat .qq/state and run records as the source of truth.")
    return trim_markdown(lines, max_chars)


def build_capsule(project_dir: Path, trigger: str, max_chars: int) -> dict[str, Any]:
    state = latest_project_state(project_dir)
    config = resolve_config(project_dir)
    compile_record = latest_stage_record(project_dir, "compile")
    test_record = latest_stage_record(project_dir, "test")
    review_record = latest_stage_record(project_dir, "review_gate")

    evidence = {
        "compile": stage_evidence(compile_record, fallback_status=str(state.get("last_compile_status") or "not_run")),
        "test": stage_evidence(test_record, fallback_status=str(state.get("last_test_status") or "not_run")),
        "reviewGate": {
            **stage_evidence(review_record, fallback_status=str(state.get("review_gate_status") or "not_started")),
            "status": str(state.get("review_gate_status") or review_record.get("status") or "not_started"),
        },
        "docDrift": {
            "status": str(state.get("doc_drift_status") or "not_checked"),
            "summary": "",
            "failureCategory": "",
            "finishedAt": "",
            "recordPath": "",
        },
    }

    payload: dict[str, Any] = {
        "schemaVersion": 1,
        "generatedAt": iso_timestamp(),
        "projectDir": str(project_dir),
        "trigger": trigger,
        "config": config,
        "objective": detect_objective(state),
        "taskFocus": state.get("task_focus") or [],
        "workMode": str(state.get("work_mode") or "feature"),
        "workModeSource": str(state.get("work_mode_source") or ""),
        "policyProfile": str(state.get("policy_profile") or "feature"),
        "policyProfileSource": str(state.get("policy_profile_source") or ""),
        "recommendedNext": str(state.get("recommended_next") or ""),
        "modeRecommendedNext": str(state.get("mode_recommended_next") or ""),
        "activeArtifacts": {
            "designDocs": state.get("design_docs") or [],
            "implementationPlans": state.get("implementation_plans") or [],
        },
        "changedFiles": state.get("changed_runtime_files") or [],
        "evidence": evidence,
        "blockers": [],
        "worktree": {
            "isManagedWorktree": bool(state.get("is_managed_worktree")),
            "role": str(state.get("worktree_role") or "primary"),
            "name": str(state.get("worktree_name") or ""),
            "branch": str(state.get("worktree_branch") or ""),
            "sourceBranch": str(state.get("worktree_source_branch") or ""),
            "sourceWorktreePath": str(state.get("worktree_source_worktree_path") or ""),
        },
        "sourceRecords": {
            "projectState": ".qq/state/project-state.json",
            "compile": evidence["compile"]["recordPath"] or ".qq/state/compile.json",
            "test": evidence["test"]["recordPath"] or ".qq/state/test.json",
            "reviewGate": evidence["reviewGate"]["recordPath"] or ".qq/state/review_gate.json",
        },
    }
    payload["blockers"] = build_blockers(state, evidence)
    payload["resumePromptMd"] = build_resume_prompt(payload, max_chars)
    return payload


def capsule_paths(project_dir: Path, trigger: str) -> dict[str, Path]:
    dirs = runtime_dirs(project_dir)
    timestamp = utc_now().strftime("%Y%m%dT%H%M%SZ")
    safe_trigger = trigger.replace("/", "-")
    return {
        "state": dirs["state"] / "context-capsule.json",
        "markdown": dirs["capsules"] / f"{timestamp}-{safe_trigger}.md",
    }


def write_capsule(project_dir: Path, payload: dict[str, Any]) -> dict[str, str]:
    paths = capsule_paths(project_dir, str(payload.get("trigger") or "manual"))
    state_path = paths["state"]
    markdown_path = paths["markdown"]
    state_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path.write_text(str(payload.get("resumePromptMd") or "") + "\n", encoding="utf-8")
    return {
        "statePath": str(state_path),
        "markdownPath": str(markdown_path),
    }


def build_capsule_state(project_dir: Path) -> dict[str, Any]:
    path = project_dir / ".qq" / "state" / "context-capsule.json"
    config = resolve_config(project_dir)
    payload = load_optional_json(path)
    if not payload:
        return {
            "path": str(path),
            "exists": False,
            "generatedAt": "",
            "trigger": "",
            "recommendedNext": "",
            "blockerCount": 0,
            "resumePromptChars": 0,
            "config": config,
        }
    blockers = payload.get("blockers") or []
    prompt = str(payload.get("resumePromptMd") or "")
    return {
        "path": str(path),
        "exists": True,
        "generatedAt": str(payload.get("generatedAt") or ""),
        "trigger": str(payload.get("trigger") or ""),
        "recommendedNext": str(payload.get("recommendedNext") or ""),
        "blockerCount": len(blockers) if isinstance(blockers, list) else 0,
        "resumePromptChars": len(prompt),
        "workMode": str(payload.get("workMode") or ""),
        "policyProfile": str(payload.get("policyProfile") or ""),
        "config": config,
    }


def load_or_build_capsule(project_dir: Path, *, refresh: bool = False) -> dict[str, Any]:
    path = project_dir / ".qq" / "state" / "context-capsule.json"
    if not refresh:
        payload = load_optional_json(path)
        if payload:
            return payload
    payload = build_capsule(project_dir, "resume", int(resolve_config(project_dir).get("maxChars") or DEFAULT_CONTEXT_CAPSULE["max_chars"]))
    payload.update(write_capsule(project_dir, payload))
    return payload


def normalize_agent_name(value: str) -> str:
    agent = str(value or "").strip().lower()
    return agent or "generic"


def should_auto_consume(state: dict[str, Any], capsule_status: dict[str, Any]) -> tuple[bool, str]:
    config = capsule_status.get("config") or {}
    if not isinstance(config, dict):
        return False, "config_missing"
    if not config.get("enabled") or config.get("mode") != "auto":
        return False, "config_off"

    compile_status = str(state.get("last_compile_status") or "")
    test_status = str(state.get("last_test_status") or "")
    if compile_status in {"failed", "blocked"}:
        return True, "compile_blocker"
    if test_status in {"failed", "blocked"}:
        return True, "test_blocker"

    if capsule_status.get("exists"):
        trigger = str(capsule_status.get("trigger") or "")
        if trigger in CONTINUATION_TRIGGERS:
            return True, f"capsule:{trigger}"

    if bool(state.get("is_managed_worktree")):
        return True, "managed_worktree"

    changed_files = state.get("changed_runtime_files") or []
    if isinstance(changed_files, list) and changed_files:
        return True, "changed_runtime_files"

    if bool(state.get("has_uncommitted_runtime_changes")):
        return True, "uncommitted_changes"

    return False, "no_continuation_signal"


def build_resume_consumer_prompt(payload: dict[str, Any], note: str = "") -> str:
    resume_prompt = str(payload.get("resumePromptMd") or "").strip()
    source_records = payload.get("sourceRecords") or {}
    lines = [
        "Use the following qq Context Capsule to resume work on this project.",
        "",
        resume_prompt,
        "",
        "Resume rules:",
        "- Treat the capsule as a handoff, not the source of truth.",
        "- Re-read the referenced `.qq/state` and run-record artifacts before making irreversible changes.",
        "- Re-check whether `recommendedNext` is still valid against current project state.",
        "- If the state has drifted, explain the delta briefly and continue from the new best next step.",
    ]
    if source_records:
        lines.append("- Runtime artifacts to inspect first:")
        for key in ("projectState", "compile", "test", "reviewGate"):
            value = str(source_records.get(key) or "").strip()
            if value:
                lines.append(f"  - {key}: {value}")
    if note.strip():
        lines.extend(["", "Additional instruction:", note.strip()])
    return "\n".join(lines).strip() + "\n"


def build_consume_payload(
    project_dir: Path,
    *,
    agent: str = "generic",
    force: bool = False,
    refresh: bool = False,
    note: str = "",
    no_resume: bool = False,
) -> dict[str, Any]:
    normalized_agent = normalize_agent_name(agent)
    state = latest_project_state(project_dir)
    capsule_status = build_capsule_state(project_dir)

    payload: dict[str, Any] = {
        "ok": True,
        "projectDir": str(project_dir),
        "agent": normalized_agent,
        "resumeApplied": False,
        "resumeMode": "off",
        "resumeReason": "disabled",
        "resumeRefresh": refresh,
        "resumeNote": note,
        "resumePrompt": "",
        "resumePromptChars": 0,
        "capsuleStatus": capsule_status,
    }

    if no_resume:
        payload["resumeMode"] = "disabled"
        payload["resumeReason"] = "flag:no_resume"
        return payload

    if force:
        capsule_payload = load_or_build_capsule(project_dir, refresh=refresh)
        prompt = build_resume_consumer_prompt(capsule_payload, note=note)
        payload.update(
            {
                "resumeApplied": True,
                "resumeMode": "forced",
                "resumeReason": "flag:resume",
                "resumePrompt": prompt,
                "resumePromptChars": len(prompt),
                "capsuleStatus": build_capsule_state(project_dir),
            }
        )
        return payload

    auto_resume, auto_reason = should_auto_consume(state, capsule_status)
    payload["resumeMode"] = "auto"
    payload["resumeReason"] = auto_reason
    if not auto_resume:
        return payload

    capsule_payload = load_or_build_capsule(project_dir, refresh=True)
    prompt = build_resume_consumer_prompt(capsule_payload, note=note)
    payload.update(
        {
            "resumeApplied": True,
            "resumeReason": auto_reason,
            "resumeRefresh": True,
            "resumePrompt": prompt,
            "resumePromptChars": len(prompt),
            "capsuleStatus": build_capsule_state(project_dir),
        }
    )
    return payload


def command_build(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    max_chars = args.max_chars if args.max_chars is not None else resolve_config(project_dir).get("maxChars", DEFAULT_CONTEXT_CAPSULE["max_chars"])
    payload = build_capsule(project_dir, args.trigger, int(max_chars))
    if not args.no_write:
        payload.update(write_capsule(project_dir, payload))
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
    sys.stdout.write("\n")
    return 0


def command_maybe_build(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    config = resolve_config(project_dir)
    payload: dict[str, Any] = {
        "ok": True,
        "projectDir": str(project_dir),
        "trigger": args.trigger,
        "config": config,
        "built": False,
    }
    if should_auto_build(config, args.trigger):
        capsule = build_capsule(project_dir, args.trigger, int(config.get("maxChars") or DEFAULT_CONTEXT_CAPSULE["max_chars"]))
        payload["capsule"] = capsule
        payload["built"] = True
        payload.update(write_capsule(project_dir, capsule))
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
    sys.stdout.write("\n")
    return 0


def command_status(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    payload = build_capsule_state(project_dir)
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
    sys.stdout.write("\n")
    return 0


def command_config(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    payload = resolve_config(project_dir)
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
    sys.stdout.write("\n")
    return 0


def command_prompt(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    payload = load_or_build_capsule(project_dir, refresh=args.refresh)
    prompt = build_resume_consumer_prompt(payload, note=args.note or "")
    if args.pretty:
        json.dump(
            {
                "ok": True,
                "projectDir": str(project_dir),
                "trigger": str(payload.get("trigger") or ""),
                "resumePrompt": prompt,
                "resumePromptChars": len(prompt),
            },
            sys.stdout,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        sys.stdout.write("\n")
        return 0
    sys.stdout.write(prompt)
    return 0


def command_consume(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    payload = build_consume_payload(
        project_dir,
        agent=args.agent,
        force=args.force,
        refresh=args.refresh,
        note=args.note or "",
        no_resume=args.no_resume,
    )
    if args.prompt_only:
        sys.stdout.write(str(payload.get("resumePrompt") or ""))
        return 0
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
    sys.stdout.write("\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="qq context capsule helper")
    subparsers = parser.add_subparsers(dest="command_name", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", default=".", help="Project root")

    build = subparsers.add_parser("build", parents=[common], help="Build a context capsule")
    build.add_argument("--trigger", default="manual", choices=sorted(VALID_TRIGGERS))
    build.add_argument("--max-chars", type=int, default=None, help="Maximum characters for resumePromptMd")
    build.add_argument("--no-write", action="store_true", help="Do not persist context-capsule.json or markdown output")
    build.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    build.set_defaults(func=command_build)

    maybe_build = subparsers.add_parser("maybe-build", parents=[common], help="Build a context capsule only when auto-trigger config allows it")
    maybe_build.add_argument("--trigger", required=True, choices=sorted(VALID_TRIGGERS))
    maybe_build.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    maybe_build.set_defaults(func=command_maybe_build)

    status = subparsers.add_parser("status", parents=[common], help="Read the latest context capsule state")
    status.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    status.set_defaults(func=command_status)

    config = subparsers.add_parser("config", parents=[common], help="Read the effective context capsule config")
    config.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    config.set_defaults(func=command_config)

    prompt = subparsers.add_parser("prompt", parents=[common], help="Render a standard resume prompt from the latest or freshly built capsule")
    prompt.add_argument("--refresh", action="store_true", help="Rebuild the capsule first using the resume trigger")
    prompt.add_argument("--note", default="", help="Optional extra instruction appended to the resume prompt")
    prompt.add_argument("--pretty", action="store_true", help="Pretty-print JSON output instead of plain text")
    prompt.set_defaults(func=command_prompt)

    consume = subparsers.add_parser("consume", parents=[common], help="Resolve whether a host should consume Context Capsule and optionally render the prompt")
    consume.add_argument("--agent", default="generic", help="Host or agent name for telemetry and future formatting differences")
    consume.add_argument("--force", action="store_true", help="Force Context Capsule consumption even if auto continuation signals are absent")
    consume.add_argument("--refresh", action="store_true", help="Refresh the capsule first; auto-consume already refreshes by default")
    consume.add_argument("--note", default="", help="Optional extra instruction appended to the resume prompt")
    consume.add_argument("--no-resume", action="store_true", help="Disable Context Capsule consumption for this request")
    consume.add_argument("--prompt-only", action="store_true", help="Print only the resolved resume prompt")
    consume.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    consume.set_defaults(func=command_consume)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
