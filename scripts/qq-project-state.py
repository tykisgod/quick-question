#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path
from typing import Any


WORK_MODE_ALIASES = {
    "release": "hardening",
}


WORK_MODE_PROFILES: dict[str, dict[str, Any]] = {
    "prototype": {
        "description": "Fast playable spike. Keep compile green, validate the idea quickly, and record keep/drop/observe.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": False,
        "test_expectation": "targeted_or_manual",
        "changes_summary_expected": True,
    },
    "feature": {
        "description": "Build a retainable feature. Prefer a concise design, a plan, compile verification, and targeted testing.",
        "design_doc_expected": True,
        "implementation_plan_expected": True,
        "review_expected": True,
        "test_expectation": "targeted",
        "changes_summary_expected": False,
    },
    "fix": {
        "description": "Bug-fix mode. Reproduce first, make the smallest safe change, and run the regression path before moving on.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": False,
        "test_expectation": "regression",
        "changes_summary_expected": False,
    },
    "hardening": {
        "description": "Stability-sensitive work. Use it for risky refactors, release prep, or anything that needs tests and review before push.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": True,
        "test_expectation": "full_or_targeted",
        "changes_summary_expected": False,
    },
}


POLICY_PROFILES: dict[str, dict[str, Any]] = {
    "core": {
        "description": "Lowest-friction runtime baseline. Compile is required; tests and review stay advisory.",
        "compile_required": True,
        "test_expectation": "basic",
        "policy_check_expectation": "advisory",
        "review_expectation": "advisory",
        "doc_drift_expectation": "off",
    },
    "feature": {
        "description": "Balanced daily-development defaults. Compile is required; targeted tests and lightweight review are expected.",
        "compile_required": True,
        "test_expectation": "targeted",
        "policy_check_expectation": "expected",
        "review_expectation": "light",
        "doc_drift_expectation": "advisory",
    },
    "hardening": {
        "description": "Higher-confidence defaults for risky work. Expect compile, stronger tests, review, and doc/code consistency.",
        "compile_required": True,
        "test_expectation": "strong",
        "policy_check_expectation": "required",
        "review_expectation": "required",
        "doc_drift_expectation": "required",
    },
}


def find_markdown_files(root: Path, patterns: list[str]) -> list[Path]:
    found: dict[str, Path] = {}
    for pattern in patterns:
        for path in sorted(root.glob(pattern)):
            if path.is_file():
                key = str(path.resolve()).lower()
                found[key] = path
    return list(found.values())


def load_latest_run(project_dir: Path, stage: str) -> dict[str, Any] | None:
    state_path = project_dir / ".qq" / "state" / f"{stage}.json"
    if state_path.is_file():
        try:
            with state_path.open("r", encoding="utf-8") as handle:
                record = json.load(handle)
            if isinstance(record, dict):
                return record
        except Exception:
            pass

    runs_dir = project_dir / ".qq" / "runs"
    if not runs_dir.is_dir():
        return None
    for path in sorted(runs_dir.glob("*.json"), reverse=True):
        try:
            with path.open("r", encoding="utf-8") as handle:
                record = json.load(handle)
        except Exception:
            continue
        if isinstance(record, dict) and record.get("stage") == stage:
            return record
    return None


def run_git(project_dir: Path, *args: str) -> list[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=project_dir,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def has_uncommitted_cs_changes(project_dir: Path) -> tuple[bool, list[str]]:
    tracked = run_git(project_dir, "diff", "--name-only", "HEAD", "--", "*.cs")
    untracked = run_git(project_dir, "ls-files", "--others", "--exclude-standard", "--", "*.cs")
    files = sorted(set(tracked + untracked))
    return bool(files), files


def detect_review_gate(project_dir: Path) -> str:
    latest = load_latest_run(project_dir, "review_gate")
    if latest:
        return str(latest.get("status") or "unknown")

    temp_dir = Path(os.environ.get("QQ_TEMP_DIR") or os.environ.get("TMPDIR") or "/tmp")
    gate_files = sorted(temp_dir.glob("claude-codex-review-gate-*"), key=lambda path: path.stat().st_mtime, reverse=True)
    if not gate_files:
        return "not_started"

    try:
        raw = gate_files[0].read_text(encoding="utf-8").strip()
        _, count = raw.split(":", 1)
        return "verified" if int(count) > 0 else "locked"
    except Exception:
        return "unknown"


def load_policy(project_dir: Path) -> dict[str, Any]:
    def read_policy(path: Path) -> dict[str, Any]:
        if not path.is_file():
            return {}
        try:
            with path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
            if isinstance(payload, dict):
                return payload
        except Exception:
            pass
        return {}

    shared = read_policy(project_dir / "qq-policy.json")
    local = read_policy(project_dir / ".qq" / "local-policy.json")
    return {**shared, **local}


def detect_work_mode(project_dir: Path) -> tuple[str, str]:
    def normalize_mode(value: Any) -> str:
        raw = str(value or "").strip().lower()
        return WORK_MODE_ALIASES.get(raw, raw)

    def read_policy(path: Path) -> dict[str, Any]:
        if not path.is_file():
            return {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    local_policy = read_policy(project_dir / ".qq" / "local-policy.json")
    shared_policy = read_policy(project_dir / "qq-policy.json")

    local_mode = normalize_mode(local_policy.get("work_mode")) if isinstance(local_policy, dict) else ""
    if local_mode in WORK_MODE_PROFILES:
        return local_mode, "qq_local_policy"

    shared_mode = normalize_mode(shared_policy.get("work_mode")) if isinstance(shared_policy, dict) else ""
    if shared_mode in WORK_MODE_PROFILES:
        return shared_mode, "qq_policy"
    return "feature", "default"


def detect_policy_profile(project_dir: Path) -> tuple[str, str]:
    def normalize_profile(value: Any) -> str:
        return str(value or "").strip().lower()

    def read_policy(path: Path) -> dict[str, Any]:
        if not path.is_file():
            return {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    local_policy = read_policy(project_dir / ".qq" / "local-policy.json")
    shared_policy = read_policy(project_dir / "qq-policy.json")

    local_profile = normalize_profile(local_policy.get("policy_profile"))
    if local_profile in POLICY_PROFILES:
        return local_profile, "qq_local_policy"

    shared_profile = normalize_profile(shared_policy.get("policy_profile"))
    if shared_profile in POLICY_PROFILES:
        return shared_profile, "qq_policy"

    return "feature", "default"


def recommend_feature_next(state: dict[str, Any]) -> str:
    if state["has_design_doc"] and not state["has_implementation_plan"]:
        return "/qq:plan"
    if state["has_implementation_plan"] and not state["has_uncommitted_cs_changes"]:
        return "/qq:execute"
    if state["has_uncommitted_cs_changes"] and state["last_compile_status"] == "passed":
        if state["last_test_status"] not in {"passed", "warning"}:
            return "/qq:best-practice"
        return "/qq:commit-push"
    if state["has_uncommitted_cs_changes"]:
        return "/qq:best-practice"
    if state["last_compile_status"] == "passed" and state["last_test_status"] == "not_run":
        return "/qq:test"
    if state["last_test_status"] == "passed":
        return "/qq:commit-push"
    return "/qq:design"


def recommend_prototype_next(state: dict[str, Any]) -> str:
    if state["has_implementation_plan"] and not state["has_uncommitted_cs_changes"]:
        return "/qq:execute"
    if state["has_design_doc"] and not state["has_implementation_plan"]:
        return "/qq:plan"
    if state["has_uncommitted_cs_changes"]:
        return "/qq:changes" if state["last_compile_status"] == "passed" else "verify_compile"
    if state["last_test_status"] == "passed":
        return "/qq:changes"
    return "prototype_direct"


def recommend_fix_next(state: dict[str, Any]) -> str:
    if state["has_uncommitted_cs_changes"]:
        if state["last_compile_status"] == "passed" and state["last_test_status"] in {"passed", "warning"}:
            return "/qq:commit-push"
        if state["last_compile_status"] == "passed":
            return "/qq:test"
        return "verify_compile"
    return "reproduce_bug"


def recommend_hardening_next(state: dict[str, Any]) -> str:
    if state["has_uncommitted_cs_changes"]:
        if state["last_compile_status"] != "passed":
            return "verify_compile"
        if state["last_test_status"] not in {"passed", "warning"}:
            return "/qq:test"
        if state["review_gate_status"] != "verified":
            return "/qq:claude-code-review"
        if state["doc_drift_status"] != "checked":
            return "/qq:doc-drift"
        return "/qq:commit-push"
    if state["last_test_status"] in {"passed", "warning"}:
        return "/qq:doc-drift" if state["doc_drift_status"] != "checked" else "/qq:commit-push"
    return "/qq:test"


def recommend_mode_next(state: dict[str, Any]) -> str:
    work_mode = str(state.get("work_mode") or "feature")
    if work_mode == "prototype":
        return recommend_prototype_next(state)
    if work_mode == "fix":
        return recommend_fix_next(state)
    if work_mode == "hardening":
        return recommend_hardening_next(state)
    return recommend_feature_next(state)


def policy_can_override(candidate: str) -> bool:
    return candidate not in {
        "/qq:design",
        "/qq:plan",
        "/qq:execute",
        "verify_compile",
        "fix_compile",
        "reproduce_bug",
    }


def apply_core_policy_profile(state: dict[str, Any], candidate: str) -> str:
    return candidate


def apply_feature_policy_profile(state: dict[str, Any], candidate: str) -> str:
    if not policy_can_override(candidate):
        return candidate
    if state["has_uncommitted_cs_changes"] and state["last_compile_status"] == "passed":
        if candidate in {"/qq:changes", "/qq:best-practice", "/qq:claude-code-review", "/qq:doc-drift", "/qq:commit-push"} and state["last_test_status"] not in {"passed", "warning"}:
            return "/qq:test"
    return candidate


def apply_hardening_policy_profile(state: dict[str, Any], candidate: str) -> str:
    if not policy_can_override(candidate):
        return candidate
    escalation_targets = {"/qq:changes", "/qq:best-practice", "/qq:claude-code-review", "/qq:doc-drift", "/qq:commit-push"}
    if state["has_uncommitted_cs_changes"] and state["last_compile_status"] == "passed":
        if candidate in escalation_targets and state["last_test_status"] not in {"passed", "warning"}:
            return "/qq:test"
        if candidate in escalation_targets and state["review_gate_status"] != "verified":
            return "/qq:claude-code-review"
        if candidate in escalation_targets and state["doc_drift_status"] != "checked":
            return "/qq:doc-drift"
    if candidate == "/qq:commit-push":
        if state["last_test_status"] not in {"passed", "warning"}:
            return "/qq:test"
        if state["review_gate_status"] != "verified":
            return "/qq:claude-code-review"
        if state["doc_drift_status"] != "checked":
            return "/qq:doc-drift"
    return candidate


def apply_policy_profile(state: dict[str, Any], candidate: str) -> str:
    profile = str(state.get("policy_profile") or "feature")
    if profile == "core":
        return apply_core_policy_profile(state, candidate)
    if profile == "hardening":
        return apply_hardening_policy_profile(state, candidate)
    return apply_feature_policy_profile(state, candidate)


def recommend_next(state: dict[str, Any]) -> str:
    if state["has_uncommitted_cs_changes"] and state["last_compile_status"] == "not_run":
        return "verify_compile"
    if state["last_compile_status"] in {"failed", "blocked"}:
        return "fix_compile"
    if state["last_test_status"] in {"failed", "blocked"}:
        return "/qq:test"
    return apply_policy_profile(state, recommend_mode_next(state))


def build_state(project_dir: Path) -> dict[str, Any]:
    design_docs = find_markdown_files(project_dir, ["Docs/design/*.md", "docs/design/*.md"])
    implementation_plans = find_markdown_files(project_dir, ["Docs/qq/**/*_implementation.md", "docs/qq/**/*_implementation.md"])
    has_changes, changed_cs = has_uncommitted_cs_changes(project_dir)
    compile_run = load_latest_run(project_dir, "compile")
    test_run = load_latest_run(project_dir, "test")
    work_mode, work_mode_source = detect_work_mode(project_dir)
    policy_profile, policy_profile_source = detect_policy_profile(project_dir)

    state: dict[str, Any] = {
        "project_dir": str(project_dir),
        "work_mode": work_mode,
        "work_mode_source": work_mode_source,
        "mode_profile": WORK_MODE_PROFILES[work_mode],
        "policy_profile": policy_profile,
        "policy_profile_source": policy_profile_source,
        "policy_profile_expectations": POLICY_PROFILES[policy_profile],
        "has_design_doc": bool(design_docs),
        "has_implementation_plan": bool(implementation_plans),
        "design_docs": [str(path.relative_to(project_dir)) for path in design_docs[:5]],
        "implementation_plans": [str(path.relative_to(project_dir)) for path in implementation_plans[:5]],
        "has_uncommitted_cs_changes": has_changes,
        "changed_cs_files": changed_cs[:20],
        "last_compile_status": str((compile_run or {}).get("status") or "not_run"),
        "last_test_status": str((test_run or {}).get("status") or "not_run"),
        "last_compile_summary": str((compile_run or {}).get("summary") or ""),
        "last_compile_failure_category": str((compile_run or {}).get("failure_category") or ""),
        "last_test_summary": str((test_run or {}).get("summary") or ""),
        "last_test_failure_category": str((test_run or {}).get("failure_category") or ""),
        "review_gate_status": detect_review_gate(project_dir),
        "doc_drift_status": "not_checked",
    }
    state["mode_recommended_next"] = recommend_mode_next(state)
    state["recommended_next"] = recommend_next(state)
    return state


def write_state_snapshot(project_dir: Path, state: dict[str, Any]) -> None:
    state_dir = project_dir / ".qq" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / "project-state.json").open("w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="qq project state detector")
    parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON")
    parser.add_argument("--no-write", action="store_true", help="Do not persist the computed state snapshot")
    args = parser.parse_args()

    project_dir = Path(args.project).resolve()
    state = build_state(project_dir)
    if not args.no_write:
        write_state_snapshot(project_dir, state)
    print(json.dumps(state, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
