#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]


class BenchmarkError(Exception):
    pass


def iso_timestamp(value: datetime | None = None) -> str:
    return (value or datetime.now(timezone.utc)).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def save_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


def run_command(command: list[str], cwd: Path | None = None, timeout_sec: int | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
        check=False,
    )


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise BenchmarkError(f"Expected JSON object in {path}")
    return value


def load_suite(path: Path) -> dict[str, Any]:
    suite = load_json(path)
    tasks = suite.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise BenchmarkError(f"Suite {path} must define a non-empty tasks array")
    return suite


def normalize_status(value: str) -> str:
    raw = (value or "").strip().lower()
    if raw in {"passed", "failed", "skipped", "warning"}:
        return raw
    return "failed"


def task_result(task_id: str, status: str, started_at: float, summary: str, details: dict[str, Any] | None = None) -> dict[str, Any]:
    finished = time.time()
    return {
        "task_id": task_id,
        "status": normalize_status(status),
        "started_at": iso_timestamp(datetime.fromtimestamp(started_at, tz=timezone.utc)),
        "finished_at": iso_timestamp(datetime.fromtimestamp(finished, tz=timezone.utc)),
        "duration_ms": max(0, int((finished - started_at) * 1000)),
        "summary": summary,
        "details": details or {},
    }


def smoke_temp_project() -> Path:
    root = Path(tempfile.mkdtemp(prefix="qq-eval-"))
    (root / "Docs" / "design").mkdir(parents=True, exist_ok=True)
    (root / "Docs" / "qq" / "demo").mkdir(parents=True, exist_ok=True)
    return root


def run_record_smoke(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    del project_dir
    started = time.time()
    root = smoke_temp_project()
    try:
        start = run_command(
            [
                "python3",
                str(REPO_ROOT / "scripts" / "qq-run-record.py"),
                "start",
                "--project",
                str(root),
                "--stage",
                "compile",
                "--command",
                "eval_run_record_smoke",
                "--backend",
                "test",
                "--transport",
                "local",
                "--summary",
                "eval smoke start",
            ]
        )
        if start.returncode != 0:
            raise BenchmarkError(start.stderr.strip() or start.stdout.strip() or "run record start failed")

        run_id = json.loads(start.stdout)["run_id"]
        finish = run_command(
            [
                "python3",
                str(REPO_ROOT / "scripts" / "qq-run-record.py"),
                "finish",
                "--project",
                str(root),
                "--run-id",
                run_id,
                "--status",
                "passed",
                "--summary",
                "eval smoke finish",
            ]
        )
        if finish.returncode != 0:
            raise BenchmarkError(finish.stderr.strip() or finish.stdout.strip() or "run record finish failed")

        compile_state = load_json(root / ".qq" / "state" / "compile.json")
        events = (root / ".qq" / "telemetry" / "events.jsonl").read_text(encoding="utf-8").strip().splitlines()
        if compile_state.get("status") != "passed":
            raise BenchmarkError("latest compile state was not persisted as passed")
        if len(events) < 2:
            raise BenchmarkError("expected at least 2 telemetry events")

        return task_result(
            str(task.get("task_id") or "run_record_smoke"),
            "passed",
            started,
            "Run record writes runs/state/telemetry",
            {"event_count": len(events), "runtime_root": str(root / ".qq")},
        )
    except Exception as exc:
        return task_result(str(task.get("task_id") or "run_record_smoke"), "failed", started, str(exc))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def project_state_smoke(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    del project_dir
    started = time.time()
    root = smoke_temp_project()
    try:
        (root / "Docs" / "design" / "sample.md").write_text("# Sample Design\n", encoding="utf-8")
        (root / "Docs" / "qq" / "demo" / "sample_implementation.md").write_text("# Sample Implementation\n", encoding="utf-8")

        start = run_command(
            [
                "python3",
                str(REPO_ROOT / "scripts" / "qq-run-record.py"),
                "start",
                "--project",
                str(root),
                "--stage",
                "compile",
                "--command",
                "eval_project_state_smoke",
                "--backend",
                "test",
                "--transport",
                "local",
                "--summary",
                "project state smoke start",
            ]
        )
        if start.returncode != 0:
            raise BenchmarkError(start.stderr.strip() or "project state smoke start failed")
        run_id = json.loads(start.stdout)["run_id"]
        finish = run_command(
            [
                "python3",
                str(REPO_ROOT / "scripts" / "qq-run-record.py"),
                "finish",
                "--project",
                str(root),
                "--run-id",
                run_id,
                "--status",
                "passed",
                "--summary",
                "project state smoke finish",
            ]
        )
        if finish.returncode != 0:
            raise BenchmarkError(finish.stderr.strip() or "project state smoke finish failed")

        state_run = run_command(["python3", str(REPO_ROOT / "scripts" / "qq-project-state.py"), "--project", str(root)])
        if state_run.returncode != 0:
            raise BenchmarkError(state_run.stderr.strip() or state_run.stdout.strip() or "project state failed")
        state = json.loads(state_run.stdout)

        expected = {
            "work_mode": "feature",
            "work_mode_source": "default",
            "has_design_doc": True,
            "has_implementation_plan": True,
            "last_compile_status": "passed",
            "recommended_next": "/qq:execute",
        }
        for key, expected_value in expected.items():
            if state.get(key) != expected_value:
                raise BenchmarkError(f"unexpected {key}: {state.get(key)!r}")

        snapshot = load_json(root / ".qq" / "state" / "project-state.json")
        return task_result(
            str(task.get("task_id") or "project_state_smoke"),
            "passed",
            started,
            "Project state controller snapshot is generated",
            {"recommended_next": snapshot.get("recommended_next"), "project_dir": str(root)},
        )
    except Exception as exc:
        return task_result(str(task.get("task_id") or "project_state_smoke"), "failed", started, str(exc))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def policy_check_smoke(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    del project_dir
    started = time.time()
    root = smoke_temp_project()
    try:
        sample = root / "Sample.cs"
        sample.write_text(
            """using UnityEngine;

public class Sample : MonoBehaviour
{
    void Update()
    {
        GetComponent<Rigidbody>();
        SendMessage("Ping");
        if (gameObject.tag == "Player")
        {
        }
    }
}
""",
            encoding="utf-8",
        )

        result = run_command(
            [str(REPO_ROOT / "scripts" / "qq-policy-check.sh"), "--json", "Sample.cs"],
            cwd=root,
        )
        if result.returncode != 0:
            raise BenchmarkError(result.stderr.strip() or result.stdout.strip() or "policy check failed")
        payload = json.loads(result.stdout)
        rule_ids = {item["rule_id"] for item in payload.get("findings", [])}
        expected = {"get_component_in_hot_path", "send_message", "tag_compare"}
        if not expected.issubset(rule_ids):
            raise BenchmarkError(f"missing expected findings: {sorted(expected - rule_ids)}")

        return task_result(
            str(task.get("task_id") or "policy_check_smoke"),
            "passed",
            started,
            "Deterministic policy catches Unity anti-patterns",
            {"finding_count": payload.get("finding_count", 0), "rule_ids": sorted(rule_ids)},
        )
    except Exception as exc:
        return task_result(str(task.get("task_id") or "policy_check_smoke"), "failed", started, str(exc))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def unity_compile(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    started = time.time()
    task_id = str(task.get("task_id") or "unity_compile")
    if project_dir is None:
        return task_result(task_id, "skipped", started, "Skipped: no --project provided")

    script = project_dir / "scripts" / "unity-compile-smart.sh"
    if not script.is_file():
        return task_result(task_id, "skipped", started, "Skipped: project-local qq compile script not found", {"project_dir": str(project_dir)})

    timeout_sec = int(task.get("timeout_sec") or 15)
    command = ["bash", str(script), "--timeout", str(timeout_sec)]
    if task.get("mode") == "editor":
        command.append("--editor")
    elif task.get("mode") == "batch":
        command.append("--batch")

    result = run_command(command, cwd=project_dir, timeout_sec=timeout_sec + 120)
    latest_path = project_dir / ".qq" / "state" / "compile.json"
    latest = load_json(latest_path) if latest_path.is_file() else {}
    status = "passed" if result.returncode == 0 else "failed"
    return task_result(
        task_id,
        status,
        started,
        latest.get("summary") or ("Compilation benchmark passed" if status == "passed" else "Compilation benchmark failed"),
        {
            "project_dir": str(project_dir),
            "returncode": result.returncode,
            "latest_status": latest.get("status", ""),
            "failure_category": latest.get("failure_category", ""),
        },
    )


def unity_test(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    started = time.time()
    task_id = str(task.get("task_id") or "unity_test")
    if project_dir is None:
        return task_result(task_id, "skipped", started, "Skipped: no --project provided")

    script = project_dir / "scripts" / "unity-test.sh"
    if not script.is_file():
        return task_result(task_id, "skipped", started, "Skipped: project-local qq test script not found", {"project_dir": str(project_dir)})

    mode = str(task.get("mode") or "editmode")
    timeout_sec = int(task.get("timeout_sec") or 180)
    command = ["bash", str(script), mode, "--timeout", str(timeout_sec)]
    if task.get("filter"):
        command.extend(["--filter", str(task["filter"])])
    if task.get("assembly"):
        command.extend(["--assembly", str(task["assembly"])])

    result = run_command(command, cwd=project_dir, timeout_sec=timeout_sec + 300)
    latest_path = project_dir / ".qq" / "state" / "test.json"
    latest = load_json(latest_path) if latest_path.is_file() else {}
    status = "passed" if result.returncode == 0 else "failed"
    return task_result(
        task_id,
        status,
        started,
        latest.get("summary") or ("Test benchmark passed" if status == "passed" else "Test benchmark failed"),
        {
            "project_dir": str(project_dir),
            "mode": mode,
            "returncode": result.returncode,
            "latest_status": latest.get("status", ""),
            "failed": latest.get("failed", 0),
        },
    )


RUNNERS: dict[str, Any] = {
    "run_record_smoke": run_record_smoke,
    "project_state_smoke": project_state_smoke,
    "policy_check_smoke": policy_check_smoke,
    "unity_compile": unity_compile,
    "unity_test": unity_test,
}


def execute_suite(suite: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    started_at = time.time()
    results: list[dict[str, Any]] = []

    for task in suite["tasks"]:
        if not isinstance(task, dict):
            raise BenchmarkError("Each task must be an object")
        runner_name = str(task.get("runner") or task.get("task_id") or "").strip()
        if runner_name not in RUNNERS:
            raise BenchmarkError(f"Unknown benchmark runner: {runner_name}")
        results.append(RUNNERS[runner_name](task, project_dir))

    counts = {"passed": 0, "failed": 0, "skipped": 0}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1

    finished_at = time.time()
    return {
        "suite_id": suite.get("suite_id", ""),
        "description": suite.get("description", ""),
        "project_dir": str(project_dir) if project_dir else "",
        "started_at": iso_timestamp(datetime.fromtimestamp(started_at, tz=timezone.utc)),
        "finished_at": iso_timestamp(datetime.fromtimestamp(finished_at, tz=timezone.utc)),
        "duration_ms": max(0, int((finished_at - started_at) * 1000)),
        "passed": counts.get("passed", 0),
        "failed": counts.get("failed", 0),
        "skipped": counts.get("skipped", 0),
        "results": results,
    }


def default_output_path(project_dir: Path, suite_id: str) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return project_dir / ".qq" / "telemetry" / "evals" / f"{timestamp}-{suite_id}.json"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run qq benchmark suites")
    parser.add_argument("--suite", required=True, help="Path to suite JSON")
    parser.add_argument("--project", help="Optional Unity project root for project-local benchmarks")
    parser.add_argument("--output", help="Optional output path for suite result JSON")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON to stdout")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    suite = load_suite(Path(args.suite).resolve())
    project_dir = Path(args.project).resolve() if args.project else None
    result = execute_suite(suite, project_dir)

    output_path = Path(args.output).resolve() if args.output else (default_output_path(project_dir, str(result["suite_id"])) if project_dir else None)
    if output_path is not None:
        save_json(output_path, result)
        result["output_path"] = str(output_path)

    print(json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty))
    return 1 if result.get("failed", 0) else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
