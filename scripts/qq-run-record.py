#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_timestamp(value: datetime | None = None) -> str:
    return (value or utc_now()).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def runtime_dirs(project_dir: Path) -> dict[str, Path]:
    root = project_dir / ".qq"
    runs = root / "runs"
    state = root / "state"
    telemetry = root / "telemetry"
    for path in (runs, state, telemetry):
        path.mkdir(parents=True, exist_ok=True)
    return {"root": root, "runs": runs, "state": state, "telemetry": telemetry}


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return max(0, int(raw))
    except ValueError:
        return default


def parse_timestamp(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_extra_json(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("extra JSON must be an object")
    return value


def normalize_status(value: str) -> str:
    raw = (value or "").strip().lower()
    aliases = {
        "ok": "passed",
        "success": "passed",
        "passed": "passed",
        "done": "passed",
        "warn": "warning",
        "warning": "warning",
        "fail": "failed",
        "failed": "failed",
        "error": "failed",
        "blocked": "blocked",
        "skipped": "skipped",
        "running": "running",
        "started": "running",
        "pending": "pending",
        "not_run": "not_run",
        "unknown": "unknown",
    }
    return aliases.get(raw, raw or "unknown")


def find_record_path(runs_dir: Path, run_id: str) -> Path:
    matches = sorted(runs_dir.glob(f"*{run_id}.json"))
    if not matches:
        raise FileNotFoundError(f"Run record not found for run_id={run_id}")
    return matches[-1]


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"Expected object in {path}")
    return value


def save_json(path: Path, value: dict[str, Any]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


def append_jsonl(path: Path, value: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True))
        handle.write("\n")


def write_latest_state(dirs: dict[str, Path], record: dict[str, Any]) -> None:
    save_json(dirs["state"] / "latest.json", record)
    stage = str(record.get("stage") or "unknown").strip() or "unknown"
    save_json(dirs["state"] / f"{stage}.json", record)


def write_telemetry_event(dirs: dict[str, Path], event_type: str, record: dict[str, Any]) -> None:
    append_jsonl(
        dirs["telemetry"] / "events.jsonl",
        {
            "event_type": event_type,
            "timestamp": iso_timestamp(),
            "run_id": record.get("run_id", ""),
            "stage": record.get("stage", ""),
            "command": record.get("command", ""),
            "status": record.get("status", ""),
            "backend": record.get("backend", ""),
            "transport": record.get("transport", ""),
            "failure_category": record.get("failure_category", ""),
            "duration_ms": record.get("duration_ms", 0),
            "summary": record.get("summary", ""),
            "record_path": record.get("record_path", ""),
        },
    )


def prune_meta_path(dirs: dict[str, Path]) -> Path:
    return dirs["state"] / "prune-meta.json"


def load_meta(dirs: dict[str, Path]) -> dict[str, Any]:
    path = prune_meta_path(dirs)
    if not path.is_file():
        return {}
    try:
        return load_json(path)
    except Exception:
        return {}


def save_meta(dirs: dict[str, Path], value: dict[str, Any]) -> None:
    save_json(prune_meta_path(dirs), value)


def prune_runs(dirs: dict[str, Path], now: datetime, max_runs: int, max_age_days: int) -> list[str]:
    removed: list[str] = []
    files = sorted(dirs["runs"].glob("*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
    cutoff_ts = now.timestamp() - (max_age_days * 86400) if max_age_days > 0 else None

    for index, path in enumerate(files):
        age_expired = cutoff_ts is not None and path.stat().st_mtime < cutoff_ts
        count_expired = max_runs > 0 and index >= max_runs
        if age_expired or count_expired:
            removed.append(path.name)
            path.unlink(missing_ok=True)
    return removed


def rotate_telemetry_if_needed(dirs: dict[str, Path], now: datetime, max_bytes: int) -> str:
    events_path = dirs["telemetry"] / "events.jsonl"
    if not events_path.is_file() or max_bytes <= 0 or events_path.stat().st_size <= max_bytes:
        return ""

    rotated_name = f"events-{now.strftime('%Y%m%dT%H%M%SZ')}.jsonl"
    rotated_path = dirs["telemetry"] / rotated_name
    suffix = 1
    while rotated_path.exists():
        rotated_path = dirs["telemetry"] / f"events-{now.strftime('%Y%m%dT%H%M%SZ')}-{suffix}.jsonl"
        suffix += 1

    events_path.rename(rotated_path)
    return rotated_path.name


def prune_rotated_telemetry(dirs: dict[str, Path], now: datetime, max_files: int, max_age_days: int) -> list[str]:
    removed: list[str] = []
    files = sorted((path for path in dirs["telemetry"].glob("events-*.jsonl") if path.is_file()), key=lambda path: path.stat().st_mtime, reverse=True)
    cutoff_ts = now.timestamp() - (max_age_days * 86400) if max_age_days > 0 else None

    for index, path in enumerate(files):
        age_expired = cutoff_ts is not None and path.stat().st_mtime < cutoff_ts
        count_expired = max_files > 0 and index >= max_files
        if age_expired or count_expired:
            removed.append(path.name)
            path.unlink(missing_ok=True)
    return removed


def prune_runtime(
    project_dir: Path,
    *,
    max_runs: int | None = None,
    max_age_days: int | None = None,
    max_telemetry_bytes: int | None = None,
    max_telemetry_files: int | None = None,
) -> dict[str, Any]:
    dirs = runtime_dirs(project_dir)
    now = utc_now()

    effective_max_runs = max_runs if max_runs is not None else env_int("QQ_MAX_RUN_RECORDS", 200)
    effective_max_age_days = max_age_days if max_age_days is not None else env_int("QQ_MAX_RUN_AGE_DAYS", 14)
    effective_max_telemetry_bytes = max_telemetry_bytes if max_telemetry_bytes is not None else env_int("QQ_MAX_TELEMETRY_BYTES", 5 * 1024 * 1024)
    effective_max_telemetry_files = max_telemetry_files if max_telemetry_files is not None else env_int("QQ_MAX_ROTATED_TELEMETRY_FILES", 10)

    rotated_name = rotate_telemetry_if_needed(dirs, now, effective_max_telemetry_bytes)
    removed_runs = prune_runs(dirs, now, effective_max_runs, effective_max_age_days)
    removed_telemetry = prune_rotated_telemetry(dirs, now, effective_max_telemetry_files, effective_max_age_days)

    result = {
        "ok": True,
        "project_dir": str(project_dir),
        "runs_removed": removed_runs,
        "runs_removed_count": len(removed_runs),
        "telemetry_rotated": rotated_name,
        "telemetry_removed": removed_telemetry,
        "telemetry_removed_count": len(removed_telemetry),
        "max_runs": effective_max_runs,
        "max_age_days": effective_max_age_days,
        "max_telemetry_bytes": effective_max_telemetry_bytes,
        "max_telemetry_files": effective_max_telemetry_files,
    }
    return result


def maybe_prune(project_dir: Path, dirs: dict[str, Path]) -> None:
    write_interval = env_int("QQ_PRUNE_WRITE_INTERVAL", 20)
    min_interval_sec = env_int("QQ_PRUNE_MIN_INTERVAL_SEC", 86400)
    meta = load_meta(dirs)
    writes_since_prune = int(meta.get("writes_since_prune") or 0) + 1
    last_pruned_at = parse_timestamp(str(meta.get("last_pruned_at") or ""))
    should_prune = write_interval > 0 and writes_since_prune >= write_interval

    if not should_prune and min_interval_sec > 0 and last_pruned_at is not None:
        elapsed = (utc_now() - last_pruned_at).total_seconds()
        should_prune = elapsed >= min_interval_sec

    if should_prune:
        result = prune_runtime(project_dir)
        meta = {
            "last_pruned_at": iso_timestamp(),
            "writes_since_prune": 0,
            "last_result": result,
        }
    else:
        meta["writes_since_prune"] = writes_since_prune
        if "last_pruned_at" not in meta:
            meta["last_pruned_at"] = ""

    save_meta(dirs, meta)


def command_start(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    dirs = runtime_dirs(project_dir)

    started = utc_now()
    run_id = args.run_id or uuid.uuid4().hex[:12]
    record = {
        "run_id": run_id,
        "command": args.command,
        "stage": args.stage,
        "status": normalize_status(args.status or "running"),
        "backend": args.backend or "",
        "transport": args.transport or "",
        "started_at": iso_timestamp(started),
        "finished_at": "",
        "duration_ms": 0,
        "failure_category": "",
        "summary": args.summary or "",
        "artifacts": {},
        "details": {},
    }
    record.update(parse_extra_json(args.extra_json))

    timestamp = started.strftime("%Y%m%dT%H%M%SZ")
    path = dirs["runs"] / f"{timestamp}-{args.stage}-{run_id}.json"
    record["record_path"] = str(path.relative_to(project_dir))
    save_json(path, record)
    write_latest_state(dirs, record)
    write_telemetry_event(dirs, "start", record)
    print(json.dumps({"run_id": run_id, "path": str(path)}, ensure_ascii=False))
    return 0


def command_finish(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    dirs = runtime_dirs(project_dir)
    path = Path(args.path).resolve() if args.path else find_record_path(dirs["runs"], args.run_id)
    record = load_json(path)

    finished = utc_now()
    started_at = record.get("started_at")
    duration_ms = 0
    if isinstance(started_at, str) and started_at:
        try:
            started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
            duration_ms = max(0, int((finished - started).total_seconds() * 1000))
        except ValueError:
            duration_ms = 0

    record["status"] = normalize_status(args.status or record.get("status") or "unknown")
    record["finished_at"] = iso_timestamp(finished)
    record["duration_ms"] = int(args.duration_ms) if args.duration_ms is not None else duration_ms
    record["failure_category"] = args.failure_category or record.get("failure_category") or ""
    if args.summary is not None:
        record["summary"] = args.summary

    extra = parse_extra_json(args.extra_json)
    for key, value in extra.items():
        record[key] = value

    save_json(path, record)
    write_latest_state(dirs, record)
    write_telemetry_event(dirs, "finish", record)
    maybe_prune(project_dir, dirs)
    print(json.dumps({"run_id": record["run_id"], "path": str(path), "status": record["status"]}, ensure_ascii=False))
    return 0


def command_latest(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    dirs = runtime_dirs(project_dir)
    matches = sorted(dirs["runs"].glob("*.json"), reverse=True)

    for path in matches:
        record = load_json(path)
        if args.stage and record.get("stage") != args.stage:
            continue
        if args.command and record.get("command") != args.command:
            continue
        if args.status and normalize_status(str(record.get("status") or "")) != normalize_status(args.status):
            continue
        print(json.dumps(record, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty))
        return 0

    print("{}")
    return 1


def command_prune(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    result = prune_runtime(
        project_dir,
        max_runs=args.max_runs,
        max_age_days=args.max_age_days,
        max_telemetry_bytes=args.max_telemetry_bytes,
        max_telemetry_files=args.max_telemetry_files,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="qq runtime run record helper")
    subparsers = parser.add_subparsers(dest="command_name", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", required=True, help="Unity project root")

    start = subparsers.add_parser("start", parents=[common], help="Create a new run record")
    start.add_argument("--run-id", help="Optional explicit run id")
    start.add_argument("--stage", required=True)
    start.add_argument("--command", required=True)
    start.add_argument("--status", default="running")
    start.add_argument("--backend")
    start.add_argument("--transport")
    start.add_argument("--summary")
    start.add_argument("--extra-json")
    start.set_defaults(func=command_start)

    finish = subparsers.add_parser("finish", parents=[common], help="Finish an existing run record")
    finish.add_argument("--run-id")
    finish.add_argument("--path")
    finish.add_argument("--status", required=True)
    finish.add_argument("--duration-ms", type=int)
    finish.add_argument("--failure-category")
    finish.add_argument("--summary")
    finish.add_argument("--extra-json")
    finish.set_defaults(func=command_finish)

    latest = subparsers.add_parser("latest", parents=[common], help="Read the latest run record")
    latest.add_argument("--stage")
    latest.add_argument("--command")
    latest.add_argument("--status")
    latest.add_argument("--pretty", action="store_true")
    latest.set_defaults(func=command_latest)

    prune = subparsers.add_parser("prune", parents=[common], help="Prune old runtime records and rotate telemetry")
    prune.add_argument("--max-runs", type=int, help="Maximum number of run record files to keep")
    prune.add_argument("--max-age-days", type=int, help="Maximum age in days for run records and rotated telemetry")
    prune.add_argument("--max-telemetry-bytes", type=int, help="Rotate telemetry when events.jsonl exceeds this size")
    prune.add_argument("--max-telemetry-files", type=int, help="Maximum number of rotated telemetry files to keep")
    prune.add_argument("--pretty", action="store_true")
    prune.set_defaults(func=command_prune)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:  # pragma: no cover - CLI wrapper
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
