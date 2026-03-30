#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path
from typing import Any


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


def recommend_next(state: dict[str, Any]) -> str:
    if state["has_design_doc"] and not state["has_implementation_plan"]:
        return "/qq:plan"
    if state["has_implementation_plan"] and not state["has_uncommitted_cs_changes"]:
        return "/qq:execute"
    if state["last_compile_status"] in {"failed", "blocked"}:
        return "fix_compile"
    if state["last_test_status"] in {"failed", "blocked"}:
        return "/qq:test"
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


def build_state(project_dir: Path) -> dict[str, Any]:
    design_docs = find_markdown_files(project_dir, ["Docs/design/*.md", "docs/design/*.md"])
    implementation_plans = find_markdown_files(project_dir, ["Docs/qq/**/*_implementation.md", "docs/qq/**/*_implementation.md"])
    has_changes, changed_cs = has_uncommitted_cs_changes(project_dir)
    compile_run = load_latest_run(project_dir, "compile")
    test_run = load_latest_run(project_dir, "test")

    state: dict[str, Any] = {
        "project_dir": str(project_dir),
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
