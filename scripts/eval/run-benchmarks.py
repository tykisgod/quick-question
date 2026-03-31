#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
import textwrap
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


def run_command(
    command: list[str],
    cwd: Path | None = None,
    timeout_sec: int | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=True,
        timeout=timeout_sec,
        check=False,
        env=env,
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
    if "schema_version" not in suite:
        suite["schema_version"] = 1
    if "benchmark_family" not in suite:
        suite["benchmark_family"] = str(suite.get("suite_id") or "")
    if "benchmark_version" not in suite:
        suite["benchmark_version"] = "0.1"
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
    prepare_unity_fixture(root)
    return root


def prepare_unity_fixture(project_dir: Path) -> None:
    (project_dir / "ProjectSettings").mkdir(parents=True, exist_ok=True)
    (project_dir / "Packages").mkdir(parents=True, exist_ok=True)
    write_text_file(
        project_dir / "ProjectSettings" / "ProjectVersion.txt",
        """
        m_EditorVersion: 2022.3.17f1
        """,
    )
    write_json_file(project_dir / "Packages" / "manifest.json", {"dependencies": {}})


def init_git_repo(project_dir: Path) -> None:
    result = run_command(["git", "init", "-q"], cwd=project_dir)
    if result.returncode != 0:
        raise BenchmarkError(result.stderr.strip() or result.stdout.strip() or f"git init failed for {project_dir}")


def commit_all(project_dir: Path, message: str) -> None:
    add_result = run_command(["git", "add", "."], cwd=project_dir)
    if add_result.returncode != 0:
        raise BenchmarkError(add_result.stderr.strip() or add_result.stdout.strip() or f"git add failed for {project_dir}")
    commit_result = run_command(
        [
            "git",
            "-c",
            "user.name=qq eval",
            "-c",
            "user.email=qq-eval@example.invalid",
            "commit",
            "-qm",
            message,
        ],
        cwd=project_dir,
    )
    if commit_result.returncode != 0:
        raise BenchmarkError(commit_result.stderr.strip() or commit_result.stdout.strip() or f"git commit failed for {project_dir}")


def write_json_file(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_text_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def write_yaml_file(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text).strip() + "\n", encoding="utf-8")


def ensure_baseline_repo(project_dir: Path) -> None:
    prepare_unity_fixture(project_dir)
    write_text_file(project_dir / "README.md", "# qq benchmark fixture\n")
    init_git_repo(project_dir)
    commit_all(project_dir, "baseline")


def apply_file_specs(project_dir: Path, specs: list[dict[str, Any]]) -> None:
    for spec in specs:
        if not isinstance(spec, dict):
            raise BenchmarkError("file spec must be an object")
        relative = str(spec.get("path") or "").strip()
        if not relative:
            raise BenchmarkError("file spec missing path")
        kind = str(spec.get("kind") or "text").strip().lower()
        target = project_dir / relative
        if kind == "json":
            payload = spec.get("value")
            if not isinstance(payload, dict):
                raise BenchmarkError(f"json file spec for {relative} must provide an object value")
            write_json_file(target, payload)
        else:
            write_text_file(target, str(spec.get("content") or ""))


def apply_runtime_config(project_dir: Path, shared_config: dict[str, Any] | None = None, local_config: dict[str, Any] | None = None) -> None:
    if shared_config is not None:
        write_json_file(project_dir / "qq.yaml", dict(shared_config))
    if local_config is not None:
        write_json_file(project_dir / ".qq" / "local.yaml", dict(local_config))


def run_project_state(project_dir: Path) -> dict[str, Any]:
    result = run_command(["python3", str(REPO_ROOT / "scripts" / "qq-project-state.py"), "--project", str(project_dir)])
    if result.returncode != 0:
        raise BenchmarkError(result.stderr.strip() or result.stdout.strip() or f"qq-project-state failed for {project_dir}")
    payload = json.loads(result.stdout)
    if not isinstance(payload, dict):
        raise BenchmarkError("qq-project-state returned a non-object payload")
    return payload


def record_stage_result(project_dir: Path, stage: str, command_name: str, summary: str, status: str) -> None:
    start = run_command(
        [
            "python3",
            str(REPO_ROOT / "scripts" / "qq-run-record.py"),
            "start",
            "--project",
            str(project_dir),
            "--stage",
            stage,
            "--command",
            command_name,
            "--backend",
            "test",
            "--transport",
            "local",
            "--summary",
            f"{summary} start",
        ]
    )
    if start.returncode != 0:
        raise BenchmarkError(start.stderr.strip() or start.stdout.strip() or f"failed to start {stage} run")
    run_id = json.loads(start.stdout)["run_id"]
    finish = run_command(
        [
            "python3",
            str(REPO_ROOT / "scripts" / "qq-run-record.py"),
            "finish",
            "--project",
            str(project_dir),
            "--run-id",
            run_id,
            "--status",
            status,
            "--summary",
            summary,
        ]
    )
    if finish.returncode != 0:
        raise BenchmarkError(finish.stderr.strip() or finish.stdout.strip() or f"failed to finish {stage} run")


def assert_expected_subset(payload: dict[str, Any], expected: dict[str, Any], *, label: str) -> None:
    for key, expected_value in expected.items():
        actual_value = payload.get(key)
        if actual_value != expected_value:
            raise BenchmarkError(f"{label}: expected {key}={expected_value!r}, got {actual_value!r}")


def list_changed_files(project_dir: Path, *patterns: str) -> list[str]:
    tracked_command = ["git", "diff", "--name-only", "HEAD"]
    untracked_command = ["git", "ls-files", "--others", "--exclude-standard"]
    if patterns:
        tracked_command.extend(["--", *patterns])
        untracked_command.extend(["--", *patterns])
    tracked = run_command(tracked_command, cwd=project_dir)
    untracked = run_command(untracked_command, cwd=project_dir)
    if tracked.returncode != 0:
        raise BenchmarkError(tracked.stderr.strip() or tracked.stdout.strip() or "git diff failed")
    if untracked.returncode != 0:
        raise BenchmarkError(untracked.stderr.strip() or untracked.stdout.strip() or "git ls-files failed")
    changed = {line.strip() for line in tracked.stdout.splitlines() if line.strip()}
    changed.update(line.strip() for line in untracked.stdout.splitlines() if line.strip())
    return sorted(changed)


def run_policy_check(project_dir: Path, spec: dict[str, Any]) -> dict[str, Any]:
    command = [str(REPO_ROOT / "scripts" / "qq-policy-check.sh"), "--json", "--project", str(project_dir)]
    config_path = spec.get("config")
    if config_path:
        command.extend(["--config", str((project_dir / str(config_path)).resolve())])
    for relative in list(spec.get("files") or []):
        command.append(str(relative))
    result = run_command(command, cwd=project_dir)
    if result.returncode != 0:
        raise BenchmarkError(result.stderr.strip() or result.stdout.strip() or "policy check failed")
    payload = json.loads(result.stdout)
    if not isinstance(payload, dict):
        raise BenchmarkError("policy check returned a non-object payload")
    return payload


def trim_output(value: str, *, max_chars: int = 4000) -> str:
    text = value.strip()
    if len(text) <= max_chars:
        return text
    return text[-max_chars:]


def render_placeholders(value: str, context: dict[str, str]) -> str:
    rendered = value
    for key, replacement in context.items():
        rendered = rendered.replace("{" + key + "}", replacement)
    return rendered


def run_solver_command(project_dir: Path, task: dict[str, Any], prompt: str) -> dict[str, Any]:
    solver = task.get("solver") or {}
    if not isinstance(solver, dict):
        raise BenchmarkError("solver must be an object")

    task_id = str(task.get("task_id") or "solver_fixture_case")
    prompt_path = project_dir / ".qq" / "telemetry" / "evals" / f"{task_id}-prompt.txt"
    write_text_file(prompt_path, prompt.rstrip() + "\n")

    context = {
        "repo_root": str(REPO_ROOT),
        "project_dir": str(project_dir),
        "task_id": task_id,
        "prompt_file": str(prompt_path),
    }
    timeout_sec = int(solver.get("timeout_sec") or 120)
    expected_exit_code = int(solver.get("expected_exit_code") or 0)

    command_spec = solver.get("command")
    shell_spec = solver.get("shell")
    if isinstance(command_spec, list):
        command = [render_placeholders(str(part), context) for part in command_spec]
        result = run_command(command, cwd=project_dir, timeout_sec=timeout_sec)
        invocation = {"command": command}
    elif isinstance(shell_spec, str) and shell_spec.strip():
        shell_command = render_placeholders(shell_spec, context)
        result = run_command(["zsh", "-lc", shell_command], cwd=project_dir, timeout_sec=timeout_sec)
        invocation = {"shell": shell_command}
    else:
        raise BenchmarkError("solver must define command[] or shell")

    if result.returncode != expected_exit_code:
        raise BenchmarkError(
            f"solver for {task_id} returned {result.returncode}, expected {expected_exit_code}: {trim_output(result.stderr or result.stdout)}"
        )

    details = {
        "expected_exit_code": expected_exit_code,
        "returncode": result.returncode,
        "timeout_sec": timeout_sec,
        "prompt_file": str(prompt_path.relative_to(project_dir)),
        "stdout": trim_output(result.stdout),
        "stderr": trim_output(result.stderr),
    }
    details.update(invocation)
    return details


def execute_code_checks(project_dir: Path, checks: dict[str, Any], *, label: str) -> dict[str, Any]:
    if not isinstance(checks, dict):
        raise BenchmarkError(f"{label}: checks must be an object")

    details: dict[str, Any] = {}

    policy_spec = checks.get("policy_check")
    if policy_spec is not None:
        if not isinstance(policy_spec, dict):
            raise BenchmarkError(f"{label}: policy_check must be an object")
        payload = run_policy_check(project_dir, policy_spec)
        rule_ids = sorted({str(item.get("rule_id") or "") for item in payload.get("findings", []) if isinstance(item, dict)})
        if "ok" in policy_spec and bool(payload.get("ok")) != bool(policy_spec["ok"]):
            raise BenchmarkError(f"{label}: expected policy ok={policy_spec['ok']!r}, got {payload.get('ok')!r}")
        if "finding_count" in policy_spec and int(payload.get("finding_count", -1)) != int(policy_spec["finding_count"]):
            raise BenchmarkError(
                f"{label}: expected policy finding_count={policy_spec['finding_count']!r}, got {payload.get('finding_count')!r}"
            )
        include = {str(item) for item in list(policy_spec.get("rule_ids_include") or [])}
        missing = include.difference(rule_ids)
        if missing:
            raise BenchmarkError(f"{label}: missing policy rule ids {sorted(missing)!r}")
        exclude = {str(item) for item in list(policy_spec.get("rule_ids_exclude") or [])}
        present = exclude.intersection(rule_ids)
        if present:
            raise BenchmarkError(f"{label}: unexpected policy rule ids {sorted(present)!r}")
        details["policy_check"] = {
            "ok": bool(payload.get("ok")),
            "finding_count": int(payload.get("finding_count", 0)),
            "rule_ids": rule_ids,
            "files_scanned": list(payload.get("files_scanned", [])),
        }

    project_state_expect = checks.get("project_state")
    if project_state_expect is not None:
        if not isinstance(project_state_expect, dict):
            raise BenchmarkError(f"{label}: project_state must be an object")
        state = run_project_state(project_dir)
        assert_expected_subset(state, project_state_expect, label=f"{label} project_state")
        details["project_state"] = {key: state.get(key) for key in project_state_expect}

    expected_changed_files = checks.get("changed_files")
    if expected_changed_files is not None:
        if not isinstance(expected_changed_files, list):
            raise BenchmarkError(f"{label}: changed_files must be an array")
        actual_changed_files = [relative for relative in list_changed_files(project_dir) if not relative.startswith(".qq/")]
        desired = sorted(str(item) for item in expected_changed_files)
        if actual_changed_files != desired:
            raise BenchmarkError(f"{label}: expected changed_files={desired!r}, got {actual_changed_files!r}")
        details["changed_files"] = actual_changed_files

    return details


def collaboration_multi_actor(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    del project_dir
    started = time.time()
    root = Path(tempfile.mkdtemp(prefix="qq-collab-eval-"))

    def make_workspace(name: str) -> Path:
        ws = root / name
        (ws / "Docs" / "design").mkdir(parents=True, exist_ok=True)
        (ws / ".qq").mkdir(parents=True, exist_ok=True)
        write_yaml_file(
            ws / "qq.yaml",
            """
            version: 1
            engine: unity
            default_profile: feature
            work_mode: feature
            """,
        )
        (ws / "Docs" / "design" / "crew_weapon.md").write_text("# Crew Weapon\n", encoding="utf-8")
        (ws / "Docs" / "design" / "map_refactor.md").write_text("# Map Refactor\n", encoding="utf-8")
        init_git_repo(ws)
        commit_all(ws, "baseline")
        return ws

    try:
        workspace_a = make_workspace("engineer-a-prototype")
        workspace_b = make_workspace("engineer-b-feature")
        workspace_c = make_workspace("engineer-c-hardening")

        # A: prototype spike with a new uncompiled C# change, then fresh compile.
        write_yaml_file(
            workspace_a / ".qq" / "local.yaml",
            """
            work_mode: prototype
            policy_profile: hardening
            """,
        )
        (workspace_a / "SeaMonsterSpike.cs").write_text(
            "using UnityEngine;\n\npublic class SeaMonsterSpike : MonoBehaviour {}\n",
            encoding="utf-8",
        )
        a_before = run_project_state(workspace_a)
        if a_before.get("recommended_next") != "verify_compile":
            raise BenchmarkError(f"engineer A expected verify_compile before compile, got {a_before.get('recommended_next')!r}")
        if a_before.get("has_design_doc") is not False:
            raise BenchmarkError("engineer A should not inherit unrelated repo-global design docs during prototype spike")
        record_stage_result(workspace_a, "compile", "collab_a_compile", "engineer A compile passed", "passed")
        a_after = run_project_state(workspace_a)
        if a_after.get("recommended_next") != "/qq:test":
            raise BenchmarkError(f"engineer A expected /qq:test after fresh compile under hardening, got {a_after.get('recommended_next')!r}")

        # B: feature iteration with focused design doc selection.
        write_yaml_file(
            workspace_b / ".qq" / "local.yaml",
            """
            work_mode: feature
            policy_profile: feature
            task_focus: crew weapon
            """,
        )
        b_state = run_project_state(workspace_b)
        if b_state.get("design_docs") != ["Docs/design/crew_weapon.md"]:
            raise BenchmarkError(f"engineer B expected crew weapon design doc focus, got {b_state.get('design_docs')!r}")
        if b_state.get("recommended_next") != "/qq:plan":
            raise BenchmarkError(f"engineer B expected /qq:plan, got {b_state.get('recommended_next')!r}")

        # C: hardening/refactor path with review escalation.
        write_yaml_file(
            workspace_c / ".qq" / "local.yaml",
            """
            work_mode: hardening
            policy_profile: hardening
            """,
        )
        (workspace_c / "MapRefactor.cs").write_text(
            "using UnityEngine;\n\npublic class MapRefactor : MonoBehaviour {}\n",
            encoding="utf-8",
        )
        record_stage_result(workspace_c, "compile", "collab_c_compile", "engineer C compile passed", "passed")
        record_stage_result(workspace_c, "test", "collab_c_test", "engineer C tests passed", "passed")
        c_before_review = run_project_state(workspace_c)
        if c_before_review.get("recommended_next") != "/qq:claude-code-review":
            raise BenchmarkError(
                f"engineer C expected /qq:claude-code-review before review verification, got {c_before_review.get('recommended_next')!r}"
            )
        record_stage_result(workspace_c, "review_gate", "collab_c_review", "engineer C review verified", "verified")
        c_after_review = run_project_state(workspace_c)
        if c_after_review.get("recommended_next") != "/qq:doc-drift":
            raise BenchmarkError(f"engineer C expected /qq:doc-drift after review, got {c_after_review.get('recommended_next')!r}")

        return task_result(
            str(task.get("task_id") or "collaboration_multi_actor"),
            "passed",
            started,
            "Shared project defaults plus per-worktree overrides route prototype, feature, and hardening work independently.",
            {
                "engineer_a": {
                    "before": a_before.get("recommended_next"),
                    "after": a_after.get("recommended_next"),
                },
                "engineer_b": {
                    "design_docs": b_state.get("design_docs"),
                    "next": b_state.get("recommended_next"),
                },
                "engineer_c": {
                    "before_review": c_before_review.get("recommended_next"),
                    "after_review": c_after_review.get("recommended_next"),
                },
            },
        )
    except Exception as exc:
        return task_result(str(task.get("task_id") or "collaboration_multi_actor"), "failed", started, str(exc))
    finally:
        shutil.rmtree(root, ignore_errors=True)


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


def timeline_case(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    del project_dir
    started = time.time()
    root = smoke_temp_project()
    snapshots: list[dict[str, Any]] = []
    try:
        fixture = task.get("fixture") or {}
        if not isinstance(fixture, dict):
            raise BenchmarkError("fixture must be an object")

        apply_file_specs(root, list(fixture.get("baseline_files") or []))
        ensure_baseline_repo(root)

        apply_file_specs(root, list(fixture.get("working_files") or []))
        if isinstance(fixture.get("shared_config"), dict):
            apply_runtime_config(root, shared_config=dict(fixture["shared_config"]))
        if isinstance(fixture.get("local_config"), dict):
            apply_runtime_config(root, local_config=dict(fixture["local_config"]))
        for record in list(fixture.get("records") or []):
            if not isinstance(record, dict):
                raise BenchmarkError("record spec must be an object")
            record_stage_result(
                root,
                str(record.get("stage") or ""),
                str(record.get("command") or f"{task.get('task_id', 'timeline')}-{record.get('stage', 'stage')}"),
                str(record.get("summary") or f"{task.get('task_id', 'timeline')} {record.get('stage', 'stage')}"),
                str(record.get("status") or "passed"),
            )

        steps = list(task.get("steps") or [])
        if not steps:
            steps = [{"expect": task.get("expect") or {}}]

        for index, step in enumerate(steps, start=1):
            if not isinstance(step, dict):
                raise BenchmarkError("timeline step must be an object")
            if isinstance(step.get("shared_config"), dict):
                apply_runtime_config(root, shared_config=dict(step["shared_config"]))
            if isinstance(step.get("local_config"), dict):
                apply_runtime_config(root, local_config=dict(step["local_config"]))
            apply_file_specs(root, list(step.get("write_files") or []))
            for relative in list(step.get("remove_paths") or []):
                (root / str(relative)).unlink(missing_ok=True)
            for record in list(step.get("record_stages") or []):
                if not isinstance(record, dict):
                    raise BenchmarkError("record spec must be an object")
                record_stage_result(
                    root,
                    str(record.get("stage") or ""),
                    str(record.get("command") or f"{task.get('task_id', 'timeline')}-step-{index}-{record.get('stage', 'stage')}"),
                    str(record.get("summary") or f"{task.get('task_id', 'timeline')} step {index} {record.get('stage', 'stage')}"),
                    str(record.get("status") or "passed"),
                )
            state = run_project_state(root)
            expected = step.get("expect") or {}
            if expected:
                if not isinstance(expected, dict):
                    raise BenchmarkError("expect must be an object")
                assert_expected_subset(state, expected, label=f"{task.get('task_id', 'timeline')} step {index}")
            snapshots.append(
                {
                    "step": index,
                    "work_mode": state.get("work_mode"),
                    "policy_profile": state.get("policy_profile"),
                    "recommended_next": state.get("recommended_next"),
                    "last_compile_status": state.get("last_compile_status"),
                    "last_test_status": state.get("last_test_status"),
                    "review_gate_status": state.get("review_gate_status"),
                    "design_docs": state.get("design_docs", []),
                    "implementation_plans": state.get("implementation_plans", []),
                }
            )

        return task_result(
            str(task.get("task_id") or "timeline_case"),
            "passed",
            started,
            str(task.get("summary") or "Controller/runtime timeline behaves as expected"),
            {"snapshots": snapshots},
        )
    except Exception as exc:
        return task_result(str(task.get("task_id") or "timeline_case"), "failed", started, str(exc))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def worktree_lifecycle_case(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    del project_dir
    started = time.time()
    root = smoke_temp_project()
    remote_root = root.parent / f"{root.name}-origin.git"
    try:
        write_text_file(root / ".claude" / "settings.local.json", "{\n  \"plugins\": {}\n}\n")
        ensure_baseline_repo(root)

        checkout = run_command(["git", "checkout", "-qb", "feature/bench-source"], cwd=root)
        if checkout.returncode != 0:
            raise BenchmarkError(checkout.stderr.strip() or checkout.stdout.strip() or "failed to create source branch")

        remote_init = run_command(["git", "init", "--bare", "-q", str(remote_root)])
        if remote_init.returncode != 0:
            raise BenchmarkError(remote_init.stderr.strip() or remote_init.stdout.strip() or "failed to create bare remote")
        remote_add = run_command(["git", "remote", "add", "origin", str(remote_root)], cwd=root)
        if remote_add.returncode != 0:
            raise BenchmarkError(remote_add.stderr.strip() or remote_add.stdout.strip() or "failed to add remote")
        push_source = run_command(["git", "push", "-u", "origin", "feature/bench-source"], cwd=root)
        if push_source.returncode != 0:
            raise BenchmarkError(push_source.stderr.strip() or push_source.stdout.strip() or "failed to publish source branch")

        create = run_command(
            [
                "python3",
                str(REPO_ROOT / "scripts" / "qq-worktree.py"),
                "create",
                "--project",
                str(root),
                "--name",
                str(task.get("name") or "worktree-lifecycle"),
                "--pretty",
            ]
        )
        if create.returncode != 0:
            raise BenchmarkError(create.stderr.strip() or create.stdout.strip() or "worktree create failed")
        create_payload = json.loads(create.stdout)
        worktree_path = Path(str(create_payload["worktreePath"]))
        copied_files = list(create_payload.get("copiedLocalRuntimeFiles") or [])

        write_text_file(worktree_path / "BenchmarkWorktree.cs", "public class BenchmarkWorktree {}\n")
        commit_all(worktree_path, "worktree benchmark change")

        status_before = run_command(
            ["python3", str(REPO_ROOT / "scripts" / "qq-worktree.py"), "status", "--project", str(worktree_path), "--pretty"]
        )
        if status_before.returncode != 0:
            raise BenchmarkError(status_before.stderr.strip() or status_before.stdout.strip() or "worktree status failed")
        status_before_payload = json.loads(status_before.stdout)
        if not bool(status_before_payload.get("canMergeBack")):
            raise BenchmarkError("expected managed worktree to be merge-back ready after commit")

        linked_push = run_command(["git", "push", "-u", "origin", str(create_payload.get("branch") or "")], cwd=worktree_path)
        if linked_push.returncode != 0:
            raise BenchmarkError(linked_push.stderr.strip() or linked_push.stdout.strip() or "failed to publish linked worktree branch")

        closeout = run_command(
            [
                "python3",
                str(REPO_ROOT / "scripts" / "qq-worktree.py"),
                "closeout",
                "--project",
                str(worktree_path),
                "--auto-yes",
                "--delete-branch",
                "--pretty",
            ]
        )
        if closeout.returncode != 0:
            raise BenchmarkError(closeout.stderr.strip() or closeout.stdout.strip() or "worktree closeout failed")

        merged_file = root / "BenchmarkWorktree.cs"
        if not merged_file.is_file():
            raise BenchmarkError("closeout did not bring worktree file into the source worktree")

        if worktree_path.exists():
            raise BenchmarkError("worktree path still exists after closeout")

        return task_result(
            str(task.get("task_id") or "worktree_lifecycle_case"),
            "passed",
            started,
            "qq-managed worktree lifecycle completes create -> commit -> closeout",
            {
                "source_branch": "feature/bench-source",
                "managed_branch": create_payload.get("branch", ""),
                "copied_local_runtime_files": copied_files,
                "merged_file": str(merged_file.relative_to(root)),
            },
        )
    except Exception as exc:
        return task_result(str(task.get("task_id") or "worktree_lifecycle_case"), "failed", started, str(exc))
    finally:
        shutil.rmtree(root, ignore_errors=True)
        shutil.rmtree(remote_root, ignore_errors=True)


def code_fixture_case(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    del project_dir
    started = time.time()
    root = smoke_temp_project()
    task_id = str(task.get("task_id") or "code_fixture_case")
    try:
        fixture = task.get("fixture") or {}
        if not isinstance(fixture, dict):
            raise BenchmarkError("fixture must be an object")

        apply_file_specs(root, list(fixture.get("baseline_files") or []))
        if isinstance(fixture.get("shared_config"), dict):
            apply_runtime_config(root, shared_config=dict(fixture["shared_config"]))
        if isinstance(fixture.get("local_config"), dict):
            apply_runtime_config(root, local_config=dict(fixture["local_config"]))
        ensure_baseline_repo(root)

        before_checks = execute_code_checks(root, dict(task.get("before_solution") or {}), label=f"{task_id} before_solution")

        oracle_files = list(task.get("oracle_files") or [])
        if not oracle_files:
            raise BenchmarkError("code_fixture_case requires non-empty oracle_files")
        apply_file_specs(root, oracle_files)

        for record in list(task.get("post_records") or []):
            if not isinstance(record, dict):
                raise BenchmarkError("record spec must be an object")
            record_stage_result(
                root,
                str(record.get("stage") or ""),
                str(record.get("command") or f"{task_id}-{record.get('stage', 'stage')}"),
                str(record.get("summary") or f"{task_id} {record.get('stage', 'stage')}"),
                str(record.get("status") or "passed"),
            )

        after_checks = execute_code_checks(root, dict(task.get("after_solution") or {}), label=f"{task_id} after_solution")

        details = {
            "prompt": str(task.get("prompt") or ""),
            "before_solution": before_checks,
            "after_solution": after_checks,
        }
        if "changed_files" not in after_checks:
            details["changed_files"] = list_changed_files(root)

        return task_result(
            task_id,
            "passed",
            started,
            str(task.get("summary") or "Code fixture resolves against deterministic evaluator checks"),
            details,
        )
    except Exception as exc:
        return task_result(task_id, "failed", started, str(exc))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def solver_fixture_case(task: dict[str, Any], project_dir: Path | None) -> dict[str, Any]:
    del project_dir
    started = time.time()
    root = smoke_temp_project()
    task_id = str(task.get("task_id") or "solver_fixture_case")
    try:
        fixture = task.get("fixture") or {}
        if not isinstance(fixture, dict):
            raise BenchmarkError("fixture must be an object")

        apply_file_specs(root, list(fixture.get("baseline_files") or []))
        if isinstance(fixture.get("shared_config"), dict):
            apply_runtime_config(root, shared_config=dict(fixture["shared_config"]))
        if isinstance(fixture.get("local_config"), dict):
            apply_runtime_config(root, local_config=dict(fixture["local_config"]))
        ensure_baseline_repo(root)

        before_checks = execute_code_checks(root, dict(task.get("before_solution") or {}), label=f"{task_id} before_solution")
        solver_details = run_solver_command(root, task, str(task.get("prompt") or ""))

        for record in list(task.get("post_records") or []):
            if not isinstance(record, dict):
                raise BenchmarkError("record spec must be an object")
            record_stage_result(
                root,
                str(record.get("stage") or ""),
                str(record.get("command") or f"{task_id}-{record.get('stage', 'stage')}"),
                str(record.get("summary") or f"{task_id} {record.get('stage', 'stage')}"),
                str(record.get("status") or "passed"),
            )

        after_checks = execute_code_checks(root, dict(task.get("after_solution") or {}), label=f"{task_id} after_solution")

        return task_result(
            task_id,
            "passed",
            started,
            str(task.get("summary") or "Solver-driven fixture resolves against deterministic evaluator checks"),
            {
                "prompt": str(task.get("prompt") or ""),
                "solver": solver_details,
                "before_solution": before_checks,
                "after_solution": after_checks,
            },
        )
    except Exception as exc:
        return task_result(task_id, "failed", started, str(exc))
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
    "collaboration_multi_actor": collaboration_multi_actor,
    "timeline_case": timeline_case,
    "worktree_lifecycle_case": worktree_lifecycle_case,
    "code_fixture_case": code_fixture_case,
    "solver_fixture_case": solver_fixture_case,
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
        "schema_version": suite.get("schema_version", 1),
        "benchmark_family": suite.get("benchmark_family", suite.get("suite_id", "")),
        "benchmark_version": suite.get("benchmark_version", "0.1"),
        "suite_id": suite.get("suite_id", ""),
        "description": suite.get("description", ""),
        "project_dir": str(project_dir) if project_dir else "",
        "task_count": len(results),
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
