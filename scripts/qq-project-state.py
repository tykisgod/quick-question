#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

from qq_engine import verification_patterns
from qq_internal_changes import latest_change_mtime, meaningful_local_change_snapshot
from qq_internal_config import POLICY_PROFILES, WORK_MODE_PROFILES, resolve_project_config
from qq_internal_git import run_git


def normalize_focus_terms(value: Any) -> list[str]:
    items: list[str] = []
    if isinstance(value, str):
        items = [part.strip() for part in re.split(r"[,\n]+", value) if part.strip()]
    elif isinstance(value, list):
        items = [str(part).strip() for part in value if str(part).strip()]

    normalized: list[str] = []
    seen: set[str] = set()
    for item in items:
        token = re.sub(r"[^a-z0-9]+", " ", item.lower()).strip()
        if not token or token in seen:
            continue
        seen.add(token)
        normalized.append(token)
    return normalized


def parse_run_timestamp(value: Any) -> datetime | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def find_markdown_files(root: Path, patterns: list[str]) -> list[Path]:
    found: dict[str, Path] = {}
    for pattern in patterns:
        for path in sorted(root.glob(pattern)):
            if path.is_file():
                key = str(path.resolve()).lower()
                # On case-insensitive filesystems the second glob variant can
                # point at the same file with different casing. Keep the first
                # discovered path so emitted relative paths remain stable.
                found.setdefault(key, path)
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


def run_git_lines(project_dir: Path, *args: str) -> list[str]:
    result = run_git(project_dir, *args, check=False)
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def detect_uncommitted_engine_changes(project_dir: Path, engine: str) -> tuple[bool, list[str]]:
    patterns = verification_patterns(engine)
    if not patterns:
        return False, []
    files: set[str] = set()
    for pattern in patterns:
        tracked = run_git_lines(project_dir, "diff", "--name-only", "HEAD", "--", pattern)
        untracked = run_git_lines(project_dir, "ls-files", "--others", "--exclude-standard", "--", pattern)
        files.update(tracked)
        files.update(untracked)
    ordered = sorted(files)
    return bool(ordered), ordered


def is_test_runtime_file(relative_path: str, engine: str) -> bool:
    path = Path(relative_path)
    lowered_parts = [part.lower() for part in path.parts]
    stem = path.stem.lower()
    if any(part in {"tests", "test", "editmode", "playmode"} for part in lowered_parts):
        return True
    if stem.endswith("test") or stem.endswith("tests") or stem.startswith("test_") or stem.endswith("_test"):
        return True
    if engine == "godot":
        return any(part in {"gut", "gdunit4", "gdunit"} for part in lowered_parts)
    return False


def select_changed_test_files(changed_files: list[str], engine: str) -> list[str]:
    return [relative for relative in changed_files if is_test_runtime_file(relative, engine)]


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


def detect_task_focus(config: dict[str, Any]) -> tuple[list[str], str]:
    focus = normalize_focus_terms(config.get("task_focus"))
    if focus:
        if str(config.get("local_config_path") or "").endswith("local.yaml"):
            return focus, "qq_local_yaml"
        if str(config.get("shared_config_path") or "").endswith("qq.yaml"):
            return focus, "qq_yaml"
    return [], "default"


def modified_markdown_files(project_dir: Path) -> set[str]:
    tracked = run_git_lines(project_dir, "diff", "--name-only", "HEAD", "--", "*.md")
    untracked = run_git_lines(project_dir, "ls-files", "--others", "--exclude-standard", "--", "*.md")
    return set(tracked + untracked)


def detect_worktree_context(project_dir: Path) -> dict[str, Any]:
    helper = Path(__file__).resolve().parent / "qq-worktree.py"
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


def select_active_artifacts(
    project_dir: Path,
    candidates: list[Path],
    *,
    modified_files: set[str],
    task_focus: list[str],
) -> list[Path]:
    if not candidates:
        return []

    active: list[Path] = []
    for path in candidates:
        relative = str(path.relative_to(project_dir))
        normalized_relative = re.sub(r"[^a-z0-9]+", " ", relative.lower()).strip()
        if relative in modified_files:
            active.append(path)
            continue
        if task_focus and any(term in normalized_relative for term in task_focus):
            active.append(path)
            continue

    if active:
        return active
    if len(candidates) == 1:
        return candidates
    return []


def effective_run_status(run: dict[str, Any] | None, latest_change_mtime: float | None) -> tuple[str, str, bool]:
    raw_status = str((run or {}).get("status") or "not_run")
    if latest_change_mtime is None:
        return raw_status, raw_status, True
    if raw_status in {"not_run", "unknown"}:
        return raw_status, raw_status, False

    finished_at = parse_run_timestamp((run or {}).get("finished_at")) or parse_run_timestamp((run or {}).get("started_at"))
    if finished_at is None:
        return raw_status, "not_run", False

    if finished_at.timestamp() < latest_change_mtime:
        return raw_status, "not_run", False
    return raw_status, raw_status, True


def skill_enabled(state: dict[str, Any], name: str) -> bool:
    return name in set(state.get("enabled_skills") or [])


def should_recommend_add_tests(state: dict[str, Any]) -> bool:
    return (
        state["has_uncommitted_runtime_changes"]
        and state["last_compile_status"] == "passed"
        and state["last_test_status"] not in {"passed", "warning"}
        and not state["has_uncommitted_test_changes"]
        and skill_enabled(state, "add-tests")
    )


def changes_summary_fresh(state: dict[str, Any]) -> bool:
    if not state["has_meaningful_local_changes"]:
        return False
    if state["last_changes_status"] not in {"passed", "checked", "warning"}:
        return False
    recorded_paths = sorted(set(str(item) for item in state.get("last_changes_files") or [] if str(item)))
    current_paths = sorted(set(state.get("changed_files") or []))
    if not recorded_paths or recorded_paths != current_paths:
        return False
    if str(state.get("last_changes_fingerprint") or "") != str(state.get("local_change_fingerprint") or ""):
        return False
    finished_at = parse_run_timestamp(state.get("last_changes_finished_at"))
    if finished_at is None:
        return False
    latest_change = state.get("latest_local_change_mtime")
    if latest_change is None:
        return True
    return finished_at.timestamp() >= float(latest_change)


def recommend_feature_next(state: dict[str, Any]) -> str:
    if state["has_design_doc"] and not state["has_implementation_plan"] and skill_enabled(state, "plan"):
        return "/qq:plan"
    if state["has_design_doc"] and not state["has_implementation_plan"] and skill_enabled(state, "execute"):
        return "/qq:execute"
    if state["has_implementation_plan"] and not state["has_uncommitted_runtime_changes"] and skill_enabled(state, "execute"):
        return "/qq:execute"
    if state["has_uncommitted_runtime_changes"] and state["last_compile_status"] == "passed":
        if should_recommend_add_tests(state) and state["policy_profile"] in {"feature", "hardening"}:
            return "/qq:add-tests"
        if state["last_test_status"] not in {"passed", "warning"}:
            if skill_enabled(state, "best-practice"):
                return "/qq:best-practice"
            if skill_enabled(state, "test"):
                return "/qq:test"
            return "/qq:commit-push" if skill_enabled(state, "commit-push") else "feature_direct"
        return "/qq:commit-push" if skill_enabled(state, "commit-push") else "feature_direct"
    if state["has_uncommitted_runtime_changes"]:
        if skill_enabled(state, "best-practice"):
            return "/qq:best-practice"
        if skill_enabled(state, "test"):
            return "/qq:test"
        return "feature_direct"
    if state["last_compile_status"] == "passed" and state["last_test_status"] == "not_run" and skill_enabled(state, "test"):
        return "/qq:test"
    if state["last_test_status"] == "passed" and skill_enabled(state, "commit-push"):
        return "/qq:commit-push"
    if skill_enabled(state, "design"):
        return "/qq:design"
    if skill_enabled(state, "execute"):
        return "/qq:execute"
    return "feature_direct"


def recommend_prototype_next(state: dict[str, Any]) -> str:
    if state["has_implementation_plan"] and not state["has_uncommitted_runtime_changes"] and skill_enabled(state, "execute"):
        return "/qq:execute"
    if state["has_design_doc"] and not state["has_implementation_plan"] and skill_enabled(state, "plan"):
        return "/qq:plan"
    if state["has_meaningful_local_changes"]:
        if state["last_compile_status"] == "passed":
            if changes_summary_fresh(state):
                return "/qq:commit-push" if skill_enabled(state, "commit-push") else "prototype_direct"
            return "/qq:changes" if skill_enabled(state, "changes") else "prototype_direct"
        return "verify_compile"
    return "prototype_direct"


def recommend_fix_next(state: dict[str, Any]) -> str:
    if state["has_uncommitted_runtime_changes"]:
        if state["last_compile_status"] == "passed" and state["last_test_status"] in {"passed", "warning"} and skill_enabled(state, "commit-push"):
            return "/qq:commit-push"
        if state["last_compile_status"] == "passed":
            if should_recommend_add_tests(state):
                return "/qq:add-tests"
            if skill_enabled(state, "test"):
                return "/qq:test"
        return "verify_compile"
    return "reproduce_bug"


def recommend_hardening_next(state: dict[str, Any]) -> str:
    if state["has_uncommitted_runtime_changes"]:
        if state["last_compile_status"] != "passed":
            return "verify_compile"
        if should_recommend_add_tests(state):
            return "/qq:add-tests"
        if state["last_test_status"] not in {"passed", "warning"} and skill_enabled(state, "test"):
            return "/qq:test"
        if state["review_gate_status"] != "verified" and skill_enabled(state, "claude-code-review"):
            return "/qq:claude-code-review"
        if state["doc_drift_status"] != "checked" and skill_enabled(state, "doc-drift"):
            return "/qq:doc-drift"
        return "/qq:commit-push" if skill_enabled(state, "commit-push") else "feature_direct"
    if state["last_test_status"] in {"passed", "warning"}:
        if state["doc_drift_status"] != "checked" and skill_enabled(state, "doc-drift"):
            return "/qq:doc-drift"
        return "/qq:commit-push" if skill_enabled(state, "commit-push") else "feature_direct"
    return "/qq:test" if skill_enabled(state, "test") else "feature_direct"


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
        "prototype_direct",
        "feature_direct",
    }


def apply_core_policy_profile(state: dict[str, Any], candidate: str) -> str:
    return candidate


def apply_feature_policy_profile(state: dict[str, Any], candidate: str) -> str:
    if not policy_can_override(candidate):
        return candidate
    if state["has_uncommitted_runtime_changes"] and state["last_compile_status"] == "passed":
        if candidate in {"/qq:changes", "/qq:best-practice", "/qq:claude-code-review", "/qq:doc-drift", "/qq:commit-push"} and state["last_test_status"] not in {"passed", "warning"} and skill_enabled(state, "test"):
            return "/qq:test"
    return candidate


def apply_hardening_policy_profile(state: dict[str, Any], candidate: str) -> str:
    if not policy_can_override(candidate):
        return candidate
    escalation_targets = {"/qq:changes", "/qq:best-practice", "/qq:claude-code-review", "/qq:doc-drift", "/qq:commit-push"}
    if state["has_uncommitted_runtime_changes"] and state["last_compile_status"] == "passed":
        if candidate in escalation_targets and state["last_test_status"] not in {"passed", "warning"} and skill_enabled(state, "test"):
            return "/qq:test"
        if candidate in escalation_targets and state["review_gate_status"] != "verified" and skill_enabled(state, "claude-code-review"):
            return "/qq:claude-code-review"
        if candidate in escalation_targets and state["doc_drift_status"] != "checked" and skill_enabled(state, "doc-drift"):
            return "/qq:doc-drift"
    if candidate == "/qq:commit-push":
        if state["last_test_status"] not in {"passed", "warning"} and skill_enabled(state, "test"):
            return "/qq:test"
        if state["review_gate_status"] != "verified" and skill_enabled(state, "claude-code-review"):
            return "/qq:claude-code-review"
        if state["doc_drift_status"] != "checked" and skill_enabled(state, "doc-drift"):
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
    if state["has_uncommitted_runtime_changes"] and state["last_compile_status"] == "not_run":
        return "verify_compile"
    if state["last_compile_status"] in {"failed", "blocked"}:
        return "fix_compile"
    if state["last_test_status"] in {"failed", "blocked"}:
        return "/qq:test"
    return apply_policy_profile(state, recommend_mode_next(state))


def build_state(project_dir: Path) -> dict[str, Any]:
    config = resolve_project_config(project_dir)
    engine = str(config.get("engine") or "")
    all_design_docs = find_markdown_files(project_dir, ["Docs/design/*.md", "docs/design/*.md"])
    all_implementation_plans = find_markdown_files(project_dir, ["Docs/qq/**/*_implementation.md", "docs/qq/**/*_implementation.md"])
    has_changes, changed_engine_files = detect_uncommitted_engine_changes(project_dir, engine)
    changed_test_files = select_changed_test_files(changed_engine_files, engine)
    change_snapshot = meaningful_local_change_snapshot(project_dir)
    changed_files = [str(item) for item in change_snapshot.get("paths") or [] if str(item)]
    local_change_fingerprint = str(change_snapshot.get("fingerprint") or "")
    compile_run = load_latest_run(project_dir, "compile")
    test_run = load_latest_run(project_dir, "test")
    changes_run = load_latest_run(project_dir, "changes")
    work_mode = str(config.get("work_mode") or "feature")
    work_mode_source = str(config.get("work_mode_source") or "default")
    policy_profile = str(config.get("policy_profile") or "feature")
    policy_profile_source = str(config.get("policy_profile_source") or "default")
    task_focus, task_focus_source = detect_task_focus(config)
    changed_md = modified_markdown_files(project_dir)
    design_docs = select_active_artifacts(project_dir, all_design_docs, modified_files=changed_md, task_focus=task_focus)
    implementation_plans = select_active_artifacts(project_dir, all_implementation_plans, modified_files=changed_md, task_focus=task_focus)
    latest_runtime_change_mtime = latest_change_mtime(project_dir, changed_engine_files)
    latest_local_change_mtime = latest_change_mtime(project_dir, changed_files)
    compile_status_raw, compile_status_effective, compile_status_fresh = effective_run_status(compile_run, latest_runtime_change_mtime)
    test_status_raw, test_status_effective, test_status_fresh = effective_run_status(test_run, latest_runtime_change_mtime)
    changes_status_raw, changes_status_effective, changes_status_fresh = effective_run_status(changes_run, latest_local_change_mtime)
    worktree = detect_worktree_context(project_dir)

    state: dict[str, Any] = {
        "project_dir": str(project_dir),
        "config_format": str(config.get("config_format") or ""),
        "shared_config_path": str(config.get("shared_config_path") or ""),
        "local_config_path": str(config.get("local_config_path") or ""),
        "shared_config_exists": bool(config.get("shared_config_exists")),
        "local_config_exists": bool(config.get("local_config_exists")),
        "profile": str(config.get("profile") or "feature"),
        "profile_source": str(config.get("profile_source") or "default"),
        "profile_description": str(config.get("profile_description") or ""),
        "engine": engine,
        "engine_source": str(config.get("engine_source") or ""),
        "work_mode": work_mode,
        "work_mode_source": work_mode_source,
        "mode_profile": config.get("mode_profile") or WORK_MODE_PROFILES[work_mode],
        "task_focus": task_focus,
        "task_focus_source": task_focus_source,
        "policy_profile": policy_profile,
        "policy_profile_source": policy_profile_source,
        "policy_profile_expectations": config.get("policy_profile_expectations") or POLICY_PROFILES[policy_profile],
        "trust_level": str(config.get("trust_level") or "trusted"),
        "trust_level_source": str(config.get("trust_level_source") or "default"),
        "trust_level_expectations": config.get("trust_level_expectations") or {},
        "default_test_scope": str(config.get("default_test_scope") or POLICY_PROFILES[policy_profile]["default_test_scope"]),
        "packs": config.get("packs") or [],
        "pack_details": config.get("pack_details") or {},
        "enabled_skills": config.get("enabled_skills") or [],
        "enabled_hooks": config.get("enabled_hooks") or [],
        "enabled_rules": config.get("enabled_rules") or [],
        "repository_design_doc_count": len(all_design_docs),
        "repository_implementation_plan_count": len(all_implementation_plans),
        "has_design_doc": bool(design_docs),
        "has_implementation_plan": bool(implementation_plans),
        "design_docs": [str(path.relative_to(project_dir)) for path in design_docs[:5]],
        "implementation_plans": [str(path.relative_to(project_dir)) for path in implementation_plans[:5]],
        "has_uncommitted_runtime_changes": has_changes,
        "changed_runtime_files": changed_engine_files[:20],
        "has_uncommitted_test_changes": bool(changed_test_files),
        "changed_test_files": changed_test_files[:20],
        "has_meaningful_local_changes": bool(changed_files),
        "changed_files": changed_files,
        "local_change_fingerprint": local_change_fingerprint,
        "latest_local_change_mtime": latest_local_change_mtime,
        "last_compile_status_raw": compile_status_raw,
        "last_compile_status": compile_status_effective,
        "compile_status_fresh": compile_status_fresh,
        "last_test_status_raw": test_status_raw,
        "last_test_status": test_status_effective,
        "test_status_fresh": test_status_fresh,
        "last_compile_summary": str((compile_run or {}).get("summary") or ""),
        "last_compile_failure_category": str((compile_run or {}).get("failure_category") or ""),
        "last_test_summary": str((test_run or {}).get("summary") or ""),
        "last_test_failure_category": str((test_run or {}).get("failure_category") or ""),
        "last_changes_status_raw": changes_status_raw,
        "last_changes_status": changes_status_effective,
        "changes_status_fresh": changes_status_fresh,
        "last_changes_summary": str((changes_run or {}).get("summary") or ""),
        "last_changes_finished_at": str((changes_run or {}).get("finished_at") or (changes_run or {}).get("started_at") or ""),
        "last_changes_files": (changes_run or {}).get("changed_files") or [],
        "last_changes_fingerprint": str((changes_run or {}).get("changed_fingerprint") or ""),
        "review_gate_status": detect_review_gate(project_dir),
        "doc_drift_status": "not_checked",
        "is_managed_worktree": bool(worktree.get("isManagedWorktree")),
        "worktree_role": str(worktree.get("role") or "primary"),
        "worktree_name": str(worktree.get("worktreeName") or ""),
        "worktree_branch": str(worktree.get("currentBranch") or ""),
        "worktree_source_branch": str(worktree.get("sourceBranch") or ""),
        "worktree_source_worktree_path": str(worktree.get("sourceWorktreePath") or ""),
        "worktree_source_branch_merged": bool(worktree.get("sourceBranchMerged")),
        "worktree_source_branch_upstream": str(worktree.get("sourceBranchUpstream") or ""),
        "worktree_source_branch_publish_state": str(worktree.get("sourceBranchPublishState") or ""),
        "worktree_source_branch_published": bool(worktree.get("sourceBranchPublished")),
        "worktree_runtime_cache_dir": str(worktree.get("runtimeCacheDir") or ""),
        "worktree_source_runtime_cache_exists": bool(worktree.get("sourceRuntimeCacheExists")),
        "worktree_local_runtime_cache_exists": bool(worktree.get("localRuntimeCacheExists")),
        "worktree_local_runtime_cache_support_exists": bool(worktree.get("localRuntimeCacheSupportExists")),
        "worktree_can_seed_runtime_cache": bool(worktree.get("canSeedRuntimeCache")),
        "worktree_runtime_cache_seed_state": str(worktree.get("runtimeCacheSeedState") or ""),
        "worktree_runtime_cache_seed_strategy": str(worktree.get("runtimeCacheSeedStrategy") or ""),
        "worktree_can_merge_back": bool(worktree.get("canMergeBack")),
        "worktree_can_push_source": bool(worktree.get("canPushSource")),
        "worktree_can_cleanup": bool(worktree.get("canCleanup")),
    }
    state["changes_summary_fresh"] = changes_summary_fresh(state)
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
