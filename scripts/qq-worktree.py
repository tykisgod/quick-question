#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from qq_engine import (
    bridge_script,
    bridge_server_name,
    host_validation_reason,
    known_engines,
    resolve_project_engine,
    runtime_cache_dir,
    runtime_cache_support_dir,
)
from qq_internal_git import repo_root, run_git


METADATA_VERSION = 1
MANAGED_BY = "qq"
PROTECTED_SOURCE_BRANCHES = {"main", "master"}
LOCAL_RUNTIME_PATHS = [
    ".mcp.json",
    ".claude/settings.local.json",
    "qq.yaml",
    "AGENTS.md",
    "CLAUDE.md",
    "scripts",
]
BASELINE_STATE_FILES = [
    ".qq/state/compile.json",
    ".qq/state/test.json",
]
IGNORED_STATUS_PREFIXES = (
    ".qq/",
)
STATIC_IGNORED_STATUS_PATHS = {
    ".mcp.json",
    ".claude/settings.local.json",
}
IGNORED_STATUS_SEGMENTS = {
    "__pycache__",
}
IGNORED_STATUS_SUFFIXES = (
    ".pyc",
    ".pyo",
)
SCRIPT_DIR = Path(__file__).resolve().parent


@dataclass(frozen=True)
class RuntimeCacheSeedResult:
    ok: bool
    action: str
    source_path: str
    target_path: str
    strategy: str = ""
    error: str = ""


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def current_branch(project_dir: Path) -> str:
    result = run_git(project_dir, "rev-parse", "--abbrev-ref", "HEAD")
    branch = result.stdout.strip()
    if not branch or branch == "HEAD":
        raise RuntimeError("Detached HEAD is not supported for qq-managed worktree creation")
    return branch


def current_commit(project_dir: Path) -> str:
    result = run_git(project_dir, "rev-parse", "HEAD")
    return result.stdout.strip()


def has_repo_dev_docker(project_dir: Path) -> bool:
    return (project_dir / "scripts" / "docker-dev.sh").is_file() and (project_dir / ".devcontainer" / "devcontainer.json").is_file()


def shell_join(parts: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def build_recommended_execution(project_dir: Path) -> dict[str, str]:
    engine = resolve_project_engine(project_dir)
    if engine:
        return {
            "mode": "host",
            "reason": host_validation_reason(engine),
        }
    if has_repo_dev_docker(project_dir):
        return {
            "mode": "docker",
            "reason": "Repository-side qq development is standardized through scripts/docker-dev.sh in this worktree.",
        }
    return {
        "mode": "host",
        "reason": "No repo-dev Docker helper was detected in this worktree; use the host machine.",
    }


def build_closeout_command(project_dir: Path) -> str:
    local_helper = project_dir / "scripts" / "qq-worktree.py"
    if local_helper.is_file():
        return shell_join(
            [
                "python3",
                "./scripts/qq-worktree.py",
                "closeout",
                "--project",
                ".",
                "--auto-yes",
                "--delete-branch",
                "--pretty",
            ]
        )
    return shell_join(
        [
            "python3",
            str((SCRIPT_DIR / "qq-worktree.py").resolve()),
            "closeout",
            "--project",
            str(project_dir),
            "--auto-yes",
            "--delete-branch",
            "--pretty",
        ]
    )


def build_doctor_command(project_dir: Path) -> str:
    local_shell = project_dir / "scripts" / "qq-doctor.sh"
    if local_shell.is_file():
        return "./scripts/qq-doctor.sh --pretty"
    local_helper = project_dir / "scripts" / "qq-doctor.py"
    if local_helper.is_file():
        return shell_join(["python3", "./scripts/qq-doctor.py", "--pretty"])
    return shell_join(
        [
            "python3",
            str((SCRIPT_DIR / "qq-doctor.py").resolve()),
            "--project",
            str(project_dir),
            "--pretty",
        ]
    )


def build_create_next_steps(project_dir: Path, execution: dict[str, str]) -> list[dict[str, str]]:
    steps: list[dict[str, str]] = [
        {
            "label": "enter-worktree",
            "command": shell_join(["cd", str(project_dir)]),
            "reason": "Switch into the dedicated linked worktree before handing it to an agent.",
        }
    ]
    if execution["mode"] == "docker":
        steps.append(
            {
                "label": "open-repo-dev-shell",
                "command": "./scripts/docker-dev.sh shell",
                "reason": "Use the standard Docker repo-dev environment for qq-core development.",
            }
        )
        steps.append(
            {
                "label": "run-repo-dev-validation",
                "command": "./scripts/docker-dev.sh test",
                "reason": "Run the standard repo-side validation loop before handoff or merge-back.",
            }
        )
    else:
        steps.append(
            {
                "label": "inspect-worktree-state",
                "command": build_doctor_command(project_dir),
                "reason": "Inspect provider, controller, and safety guidance before host-side work starts.",
            }
        )
    steps.append(
        {
            "label": "closeout-worktree",
            "command": build_closeout_command(project_dir),
            "reason": "Merge back and clean up this linked worktree after verification is complete.",
        }
    )
    return steps


def relevant_status_lines(project_dir: Path) -> list[str]:
    result = run_git(project_dir, "status", "--porcelain", check=False)
    if result.returncode != 0:
        return ["__git_status_failed__"]
    metadata = load_metadata(project_dir)
    runtime_paths = {
        str(item)
        for item in (metadata.get("copiedLocalRuntimeFiles") or [])
        if str(item)
    }
    lines: list[str] = []
    for raw in result.stdout.splitlines():
        line = raw.rstrip()
        status = line[:2]
        path = line[3:] if len(line) > 3 else ""
        if should_ignore_status_path(project_dir, path, status, runtime_paths):
            continue
        lines.append(line)
    return lines


def is_ignored_runtime_leaf(path: Path, project_dir: Path) -> bool:
    try:
        relative = path.relative_to(project_dir).as_posix()
    except ValueError:
        relative = path.as_posix()
    if relative in STATIC_IGNORED_STATUS_PATHS:
        return True
    if any(relative.startswith(prefix) for prefix in IGNORED_STATUS_PREFIXES):
        return True
    parts = [part for part in Path(relative).parts if part not in {"."}]
    if any(part in IGNORED_STATUS_SEGMENTS for part in parts):
        return True
    if relative.endswith(IGNORED_STATUS_SUFFIXES):
        return True
    return False


def path_matches_runtime_artifact(relative_path: str, runtime_paths: set[str]) -> bool:
    normalized = Path(relative_path).as_posix().rstrip("/")
    for runtime_path in runtime_paths:
        candidate = runtime_path.rstrip("/")
        if (
            normalized == candidate
            or normalized.startswith(f"{candidate}/")
            or candidate.startswith(f"{normalized}/")
        ):
            return True
    return False


def is_tracked_path(project_dir: Path, relative_path: str) -> bool:
    result = run_git(project_dir, "ls-files", "--error-unmatch", "--", relative_path, check=False)
    return result.returncode == 0


def should_ignore_status_path(project_dir: Path, relative_path: str, status: str, runtime_paths: set[str]) -> bool:
    candidate = project_dir / relative_path
    if is_ignored_runtime_leaf(candidate, project_dir):
        return True
    if status == "??":
        dynamic_paths = set(LOCAL_RUNTIME_PATHS) | runtime_paths
        if path_matches_runtime_artifact(relative_path, dynamic_paths) and not is_tracked_path(project_dir, relative_path):
            return True
    if candidate.is_dir():
        try:
            descendants = list(candidate.rglob("*"))
        except OSError:
            return False
        if descendants and all(is_ignored_runtime_leaf(descendant, project_dir) for descendant in descendants):
            return True
    return False


def prune_untracked_runtime_tree(project_dir: Path, relative_path: str) -> list[str]:
    target = project_dir / relative_path
    if not target.exists() and not target.is_symlink():
        return []

    pruned: list[str] = []

    if target.is_file() or target.is_symlink():
        if not is_tracked_path(project_dir, relative_path):
            target.unlink(missing_ok=True)
            pruned.append(relative_path)
        return pruned

    descendants = sorted(target.rglob("*"), key=lambda path: len(path.parts), reverse=True)
    for path in descendants:
        rel = path.relative_to(project_dir).as_posix()
        if path.is_file() or path.is_symlink():
            if not is_tracked_path(project_dir, rel):
                path.unlink(missing_ok=True)
                pruned.append(rel)
            continue
        try:
            path.rmdir()
        except OSError:
            pass

    try:
        target.rmdir()
        pruned.append(relative_path.rstrip("/") + "/")
    except OSError:
        pass
    return pruned


def prune_copied_runtime_artifacts(project_dir: Path, copied_runtime_paths: list[str]) -> list[str]:
    pruned: list[str] = []
    for relative_path in sorted({str(item) for item in copied_runtime_paths if str(item)}):
        pruned.extend(prune_untracked_runtime_tree(project_dir, relative_path))
    return sorted(set(pruned))


def is_clean_worktree(project_dir: Path) -> bool:
    return relevant_status_lines(project_dir) == []


def slugify(value: str) -> str:
    token = "".join(ch.lower() if ch.isalnum() else "-" for ch in value.strip())
    while "--" in token:
        token = token.replace("--", "-")
    token = token.strip("-")
    return token or "task"


def parse_worktree_list(project_dir: Path) -> list[dict[str, Any]]:
    result = run_git(project_dir, "worktree", "list", "--porcelain")
    items: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            if current:
                items.append(current)
                current = None
            continue
        key, _, value = line.partition(" ")
        if key == "worktree":
            if current:
                items.append(current)
            current = {
                "path": value,
                "head": "",
                "branch": "",
                "detached": False,
            }
            continue
        if current is None:
            continue
        if key == "HEAD":
            current["head"] = value
        elif key == "branch":
            current["branch"] = value.removeprefix("refs/heads/")
        elif key == "detached":
            current["detached"] = True
    if current:
        items.append(current)
    return items


def metadata_path(project_dir: Path) -> Path:
    return project_dir / ".qq" / "state" / "worktree.json"


def load_metadata(project_dir: Path) -> dict[str, Any]:
    path = metadata_path(project_dir)
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def write_metadata(project_dir: Path, payload: dict[str, Any]) -> Path:
    path = metadata_path(project_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def project_local_mcp_server(project_dir: Path) -> dict[str, Any]:
    resolved = project_dir.resolve()
    return {
        "command": "python3",
        "args": [
            str((resolved / "scripts" / "qq_mcp.py").resolve()),
            "--project",
            str(resolved),
        ],
        "cwd": str(resolved),
    }


def maybe_build_context_capsule(project_dir: Path, trigger: str) -> dict[str, Any]:
    helper = Path(__file__).resolve().parent / "qq-context-capsule.py"
    if not helper.is_file():
        return {
            "available": False,
            "built": False,
            "trigger": trigger,
            "error": "qq-context-capsule.py not found",
        }

    result = subprocess.run(
        ["python3", str(helper), "maybe-build", "--project", str(project_dir), "--trigger", trigger],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return {
            "available": True,
            "built": False,
            "trigger": trigger,
            "error": result.stderr.strip() or result.stdout.strip() or "qq-context-capsule maybe-build failed",
        }
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "available": True,
            "built": False,
            "trigger": trigger,
            "error": "qq-context-capsule maybe-build returned invalid JSON",
        }
    if not isinstance(payload, dict):
        return {
            "available": True,
            "built": False,
            "trigger": trigger,
            "error": "qq-context-capsule maybe-build returned a non-object payload",
        }
    payload["available"] = True
    return payload


def is_project_bridge_server(name: str, server: dict[str, Any]) -> bool:
    known_names = {bridge_server_name(engine) for engine in known_engines() if bridge_server_name(engine)}
    if name in known_names:
        return True
    command = str(server.get("command") or "")
    raw_args = server.get("args") or []
    args = [str(item) for item in raw_args] if isinstance(raw_args, list) else []
    lowered = " ".join([name, command, *args]).lower()
    known_scripts = {bridge_script(engine).lower() for engine in known_engines() if bridge_script(engine)}
    return any(script_name in lowered for script_name in known_scripts)


def rewrite_mcp_config_for_project(config_path: Path, project_dir: Path) -> None:
    try:
        payload = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    if not isinstance(payload, dict):
        return
    raw_servers = payload.get("mcpServers")
    if not isinstance(raw_servers, dict):
        return
    updated = False
    for name, raw in list(raw_servers.items()):
        if not isinstance(raw, dict):
            continue
        if not is_project_bridge_server(str(name), raw):
            continue
        raw_servers[name] = project_local_mcp_server(project_dir)
        updated = True
    if updated:
        config_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def copy_runtime_path(src: Path, dst: Path) -> None:
    if src.is_dir():
        dst.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst, dirs_exist_ok=True)
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def copy_local_runtime_files(source_dir: Path, target_dir: Path) -> list[str]:
    copied: list[str] = []
    for relative in LOCAL_RUNTIME_PATHS:
        src = source_dir / relative
        if not src.exists():
            continue
        dst = target_dir / relative
        copy_runtime_path(src, dst)
        if relative == ".mcp.json":
            rewrite_mcp_config_for_project(dst, target_dir)
        copied.append(relative)
    return copied


def copy_baseline_state_files(source_dir: Path, target_dir: Path) -> list[str]:
    copied: list[str] = []
    for relative in BASELINE_STATE_FILES:
        src = source_dir / relative
        if not src.is_file():
            continue
        dst = target_dir / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied.append(relative)
    return copied


def load_json_object(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def copy_baseline_run_records(source_dir: Path, target_dir: Path) -> list[str]:
    copied: list[str] = []
    record_paths: set[str] = set()

    for relative in BASELINE_STATE_FILES:
        payload = load_json_object(source_dir / relative)
        record_path = str(payload.get("recordPath") or payload.get("record_path") or "").strip()
        if record_path:
            record_paths.add(record_path)

    capsule_payload = load_json_object(source_dir / ".qq" / "state" / "context-capsule.json")
    source_records = capsule_payload.get("sourceRecords") or {}
    if isinstance(source_records, dict):
        for value in source_records.values():
            record_path = str(value or "").strip()
            if record_path:
                record_paths.add(record_path)

    for relative in sorted(record_paths):
        src = source_dir / relative
        if not src.is_file():
            continue
        dst = target_dir / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied.append(relative)

    return copied


def clone_copy_tree(source_dir: Path, target_dir: Path) -> str:
    target_dir.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin":
        clone_result = subprocess.run(
            ["cp", "-cR", f"{source_dir}/.", f"{target_dir}/"],
            check=False,
            capture_output=True,
            text=True,
        )
        if clone_result.returncode == 0:
            return "clonefile"

    rsync_binary = shutil.which("rsync")
    if rsync_binary:
        rsync_result = subprocess.run(
            [rsync_binary, "-a", "--delete", f"{source_dir}/", f"{target_dir}/"],
            check=False,
            capture_output=True,
            text=True,
        )
        if rsync_result.returncode == 0:
            return "rsync"
        raise RuntimeError(rsync_result.stderr.strip() or rsync_result.stdout.strip() or "rsync failed")

    shutil.copytree(source_dir, target_dir, dirs_exist_ok=True)
    return "copytree"


def runtime_cache_paths(project_dir: Path, source_worktree: Path | None) -> tuple[str, Path | None, Path | None]:
    engine = resolve_project_engine(project_dir)
    cache_dir = runtime_cache_dir(engine)
    if not cache_dir:
        return "", None, None
    source_cache = source_worktree / cache_dir if source_worktree else None
    target_cache = project_dir / cache_dir
    return cache_dir, source_cache, target_cache


def ensure_runtime_cache_seed(project_dir: Path, source_worktree: Path | None, *, refresh: bool = False) -> RuntimeCacheSeedResult:
    cache_dir, source_cache, target_cache = runtime_cache_paths(project_dir, source_worktree)
    if not cache_dir or target_cache is None:
        return RuntimeCacheSeedResult(
            ok=False,
            action="unsupported",
            source_path="",
            target_path="",
            error="Current project does not define a seedable runtime cache",
        )
    if source_cache is None:
        return RuntimeCacheSeedResult(
            ok=False,
            action="unmanaged",
            source_path="",
            target_path=str(target_cache),
            error="Current project is not a qq-managed worktree",
        )
    if not source_cache.is_dir():
        return RuntimeCacheSeedResult(
            ok=False,
            action="source_missing",
            source_path=str(source_cache),
            target_path=str(target_cache),
            error="Source worktree has no runtime cache directory to seed from",
        )
    if target_cache.is_dir() and not refresh:
        return RuntimeCacheSeedResult(
            ok=True,
            action="already_present",
            source_path=str(source_cache),
            target_path=str(target_cache),
        )

    if refresh and target_cache.exists():
        shutil.rmtree(target_cache, ignore_errors=True)
    try:
        strategy = clone_copy_tree(source_cache, target_cache)
    except Exception as exc:
        shutil.rmtree(target_cache, ignore_errors=True)
        return RuntimeCacheSeedResult(
            ok=False,
            action="failed",
            source_path=str(source_cache),
            target_path=str(target_cache),
            error=str(exc),
        )

    return RuntimeCacheSeedResult(
        ok=True,
        action="seeded",
        source_path=str(source_cache),
        target_path=str(target_cache),
        strategy=strategy,
    )


def build_status(project_dir: Path) -> dict[str, Any]:
    root = repo_root(project_dir)
    branch = current_branch(root)
    metadata = load_metadata(root)
    engine = resolve_project_engine(root)
    cache_dir = runtime_cache_dir(engine)
    cache_support_dir = runtime_cache_support_dir(engine)
    worktrees: list[dict[str, Any]] = []
    for entry in parse_worktree_list(root):
        path = Path(str(entry.get("path") or "")).resolve()
        entry_metadata = load_metadata(path)
        worktrees.append(
            {
                "path": str(path),
                "branch": entry.get("branch") or "",
                "head": entry.get("head") or "",
                "detached": bool(entry.get("detached")),
                "isCurrent": path == root,
                "managedByQq": entry_metadata.get("managedBy") == MANAGED_BY,
                "sourceBranch": str(entry_metadata.get("sourceBranch") or ""),
                "sourceWorktreePath": str(entry_metadata.get("sourceWorktreePath") or ""),
            }
        )

    managed = metadata.get("managedBy") == MANAGED_BY
    source_worktree = Path(str(metadata.get("sourceWorktreePath") or "")).resolve() if managed and metadata.get("sourceWorktreePath") else None
    source_exists = bool(source_worktree and source_worktree.is_dir())
    source_cache = source_worktree / cache_dir if source_worktree and cache_dir else None
    local_cache = root / cache_dir if cache_dir else None
    local_cache_support = (local_cache / cache_support_dir) if local_cache and cache_support_dir else None
    source_clean = bool(source_worktree and source_exists and is_clean_worktree(source_worktree))
    source_branch = str(metadata.get("sourceBranch") or "")
    source_upstream = branch_upstream(source_worktree, source_branch) if source_worktree and source_exists and source_branch else ""
    source_publish_state = (
        branch_publish_state(source_worktree, source_branch, source_upstream)
        if source_worktree and source_exists and source_branch
        else "unknown"
    )
    source_branch_merged = (
        branch_is_ancestor(source_worktree, branch, source_branch)
        if managed and source_worktree and source_exists and source_branch and branch != source_branch
        else False
    )
    source_branch_published = source_publish_state in {"in_sync", "not_required"}
    payload = {
        "projectDir": str(root),
        "engine": engine,
        "currentBranch": branch,
        "currentCommit": current_commit(root),
        "isManagedWorktree": managed,
        "role": "managed" if managed else "primary",
        "worktreeName": str(metadata.get("worktreeName") or ""),
        "sourceBranch": source_branch,
        "sourceWorktreePath": str(source_worktree) if source_worktree else "",
        "sourceWorktreeExists": source_exists,
        "sourceWorktreeClean": source_clean if source_exists else False,
        "runtimeCacheDir": cache_dir,
        "sourceRuntimeCachePath": str(source_cache) if source_cache else "",
        "sourceRuntimeCacheExists": bool(source_cache and source_cache.is_dir()),
        "sourceBranchMerged": source_branch_merged,
        "sourceBranchUpstream": source_upstream,
        "sourceBranchPublishState": source_publish_state,
        "sourceBranchPublished": source_branch_published,
        "metadataPath": str(metadata_path(root)),
        "localRuntimeCachePath": str(local_cache) if local_cache else "",
        "localRuntimeCacheExists": bool(local_cache and local_cache.is_dir()),
        "localRuntimeCacheSupportPath": str(local_cache_support) if local_cache_support else "",
        "localRuntimeCacheSupportExists": bool(local_cache_support and local_cache_support.is_dir()),
        "runtimeCacheSeedState": str(((metadata.get("runtimeCacheSeed") or {}) if isinstance(metadata.get("runtimeCacheSeed"), dict) else {}).get("action") or ""),
        "runtimeCacheSeedStrategy": str(((metadata.get("runtimeCacheSeed") or {}) if isinstance(metadata.get("runtimeCacheSeed"), dict) else {}).get("strategy") or ""),
        "runtimeCacheSeededAt": str(((metadata.get("runtimeCacheSeed") or {}) if isinstance(metadata.get("runtimeCacheSeed"), dict) else {}).get("seededAt") or ""),
        "localChanges": not is_clean_worktree(root),
        "worktrees": worktrees,
    }
    payload["canMergeBack"] = (
        managed
        and not payload["localChanges"]
        and source_exists
        and source_clean
        and branch != payload["sourceBranch"]
        and not source_branch_merged
    )
    payload["canPushSource"] = (
        managed
        and not payload["localChanges"]
        and source_exists
        and source_clean
        and branch != payload["sourceBranch"]
        and source_branch_merged
        and not source_branch_published
    )
    payload["canCleanup"] = (
        managed
        and not payload["localChanges"]
        and source_exists
        and source_clean
        and branch != payload["sourceBranch"]
        and source_branch_merged
        and source_branch_published
    )
    payload["canSeedRuntimeCache"] = managed and source_exists and bool(source_cache and source_cache.is_dir()) and not bool(local_cache and local_cache.is_dir())
    return payload


def ensure_branch_missing(project_dir: Path, branch: str) -> None:
    result = run_git(project_dir, "show-ref", "--verify", f"refs/heads/{branch}", check=False)
    if result.returncode == 0:
        raise RuntimeError(f"Branch already exists: {branch}")
    remote_result = run_git(project_dir, "for-each-ref", "--format=%(refname:strip=2)", "refs/remotes", check=False)
    if remote_result.returncode != 0:
        return
    collisions = [
        line.strip()
        for line in remote_result.stdout.splitlines()
        if line.strip()
        and not line.strip().endswith("/HEAD")
        and line.strip().endswith(f"/{branch}")
    ]
    if collisions:
        raise RuntimeError(f"Remote branch already exists: {', '.join(collisions)}")


def branch_upstream(project_dir: Path, branch: str) -> str:
    result = run_git(project_dir, "rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}", check=False)
    if result.returncode != 0:
        return ""
    upstream = result.stdout.strip()
    return upstream if upstream and upstream != f"{branch}@{{upstream}}" else ""


def branch_publish_state(project_dir: Path, branch: str, upstream: str) -> str:
    if not upstream:
        return "not_required"
    result = run_git(project_dir, "rev-list", "--left-right", "--count", f"{upstream}...{branch}", check=False)
    if result.returncode != 0:
        return "unknown"
    parts = result.stdout.strip().split()
    if len(parts) != 2:
        return "unknown"
    behind, ahead = (int(parts[0]), int(parts[1]))
    if behind == 0 and ahead == 0:
        return "in_sync"
    if behind == 0:
        return "ahead"
    if ahead == 0:
        return "behind"
    return "diverged"


def branch_is_ancestor(project_dir: Path, ancestor: str, descendant: str) -> bool:
    result = run_git(project_dir, "merge-base", "--is-ancestor", ancestor, descendant, check=False)
    return result.returncode == 0


def default_push_remote(project_dir: Path) -> str:
    result = run_git(project_dir, "remote", check=False)
    if result.returncode != 0:
        return ""
    remotes = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not remotes:
        return ""
    if "origin" in remotes:
        return "origin"
    return remotes[0]


def parse_upstream(upstream: str) -> tuple[str, str]:
    if "/" not in upstream:
        return "", upstream
    remote, _, branch = upstream.partition("/")
    return remote, branch


def remote_branch_exists(project_dir: Path, remote: str, branch: str) -> bool:
    if not remote or not branch:
        return False
    result = run_git(project_dir, "ls-remote", "--heads", remote, f"refs/heads/{branch}", check=False)
    return result.returncode == 0 and bool(result.stdout.strip())


def command_create(args: argparse.Namespace) -> dict[str, Any]:
    project_dir = Path(args.project).resolve()
    root = repo_root(project_dir)
    if load_metadata(root).get("managedBy") == MANAGED_BY:
        raise RuntimeError("Current project is already a qq-managed worktree; create linked worktrees from the source worktree instead")
    source_branch = args.source_branch or current_branch(root)
    if not is_clean_worktree(root) and not args.allow_dirty_source:
        raise RuntimeError("Source worktree has local changes; commit or stash them first, or pass --allow-dirty-source")
    if source_branch in PROTECTED_SOURCE_BRANCHES and not args.allow_main:
        raise RuntimeError(
            f"Refusing to create a qq worktree from protected branch '{source_branch}'. "
            "Create a feature branch first or pass --allow-main."
        )

    slug = slugify(args.name)
    branch = args.branch or f"{source_branch}-wt-{slug}"
    ensure_branch_missing(root, branch)

    base_dir = Path(args.base_dir).resolve() if args.base_dir else root.parent
    target_path = Path(args.path).resolve() if args.path else (base_dir / f"{root.name}-wt-{slug}")
    if target_path.exists():
        raise RuntimeError(f"Worktree path already exists: {target_path}")

    run_git(root, "worktree", "add", "-b", branch, str(target_path), source_branch)
    copied_files = copy_local_runtime_files(root, target_path)
    copied_state_files = copy_baseline_state_files(root, target_path)
    copied_run_records = copy_baseline_run_records(root, target_path)
    runtime_cache_seed = ensure_runtime_cache_seed(target_path, root)
    metadata = {
        "managedBy": MANAGED_BY,
        "metadataVersion": METADATA_VERSION,
        "createdAt": utc_now_iso(),
        "engine": resolve_project_engine(target_path),
        "worktreeName": slug,
        "branch": branch,
        "sourceBranch": source_branch,
        "sourceWorktreePath": str(root),
        "currentPath": str(target_path),
        "copiedLocalRuntimeFiles": copied_files,
        "copiedBaselineStateFiles": copied_state_files,
        "copiedBaselineRunRecords": copied_run_records,
        "runtimeCacheSeed": {
            "action": runtime_cache_seed.action,
            "sourcePath": runtime_cache_seed.source_path,
            "targetPath": runtime_cache_seed.target_path,
            "strategy": runtime_cache_seed.strategy,
            "seededAt": utc_now_iso() if runtime_cache_seed.ok and runtime_cache_seed.action == "seeded" else "",
            "error": runtime_cache_seed.error,
        },
    }
    metadata_file = write_metadata(target_path, metadata)
    context_capsule = maybe_build_context_capsule(target_path, "worktree_handoff")
    recommended_execution = build_recommended_execution(target_path)
    next_steps = build_create_next_steps(target_path, recommended_execution)
    return {
        "ok": True,
        "action": "create",
        "projectDir": str(root),
        "sourceBranch": source_branch,
        "branch": branch,
        "worktreeName": slug,
        "worktreePath": str(target_path),
        "metadataPath": str(metadata_file),
        "copiedLocalRuntimeFiles": copied_files,
        "copiedBaselineStateFiles": copied_state_files,
        "copiedBaselineRunRecords": copied_run_records,
        "contextCapsule": context_capsule,
        "runtimeCacheSeed": {
            "ok": runtime_cache_seed.ok,
            "action": runtime_cache_seed.action,
            "sourcePath": runtime_cache_seed.source_path,
            "targetPath": runtime_cache_seed.target_path,
            "strategy": runtime_cache_seed.strategy,
            "error": runtime_cache_seed.error,
        },
        "recommendedExecution": recommended_execution,
        "parallelAgentSafe": True,
        "parallelAgentSafety": {
            "status": "ok",
            "summary": "This dedicated linked worktree is safe to hand to exactly one agent.",
            "recommendedAction": next_steps[0]["command"],
        },
        "nextSteps": next_steps,
    }


def command_status(args: argparse.Namespace) -> dict[str, Any]:
    payload = build_status(Path(args.project).resolve())
    payload["ok"] = True
    payload["action"] = "status"
    return payload


def command_seed_runtime_cache(args: argparse.Namespace) -> dict[str, Any]:
    project_dir = Path(args.project).resolve()
    status = build_status(project_dir)
    if not status["isManagedWorktree"]:
        raise RuntimeError("Current project is not a qq-managed worktree")
    source_path = Path(str(status["sourceWorktreePath"]))
    result = ensure_runtime_cache_seed(project_dir, source_path, refresh=args.refresh)

    metadata = load_metadata(project_dir)
    metadata["runtimeCacheSeed"] = {
        "action": result.action,
        "sourcePath": result.source_path,
        "targetPath": result.target_path,
        "strategy": result.strategy,
        "seededAt": utc_now_iso() if result.ok and result.action == "seeded" else str(((metadata.get("runtimeCacheSeed") or {}) if isinstance(metadata.get("runtimeCacheSeed"), dict) else {}).get("seededAt") or ""),
        "error": result.error,
    }
    write_metadata(project_dir, metadata)

    return {
        "ok": result.ok,
        "action": "seed-runtime-cache",
        "runtimeCacheSeed": {
            "action": result.action,
            "sourcePath": result.source_path,
            "targetPath": result.target_path,
            "strategy": result.strategy,
            "error": result.error,
        },
    }


def command_merge_back(args: argparse.Namespace) -> dict[str, Any]:
    project_dir = Path(args.project).resolve()
    status = build_status(project_dir)
    if not status["isManagedWorktree"]:
        raise RuntimeError("Current project is not a qq-managed worktree")
    if status["localChanges"]:
        raise RuntimeError("Current worktree has uncommitted changes; commit or stash before merge-back")

    source_path = Path(str(status["sourceWorktreePath"]))
    source_branch = str(status["sourceBranch"])
    current_branch_name = str(status["currentBranch"])
    if not source_path.is_dir():
        raise RuntimeError(f"Source worktree path not found: {source_path}")
    if not is_clean_worktree(source_path):
        raise RuntimeError(f"Source worktree is not clean: {source_path}")
    if status["sourceBranchMerged"]:
        raise RuntimeError("Current linked branch is already merged into the source branch")

    run_git(source_path, "checkout", source_branch)
    merge_args = ["merge", "--no-ff"]
    if args.auto_yes:
        merge_args.append("--no-edit")
    merge_args.append(current_branch_name)
    result = run_git(source_path, *merge_args, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "git merge failed")

    push_stdout = ""
    source_upstream = branch_upstream(source_path, source_branch)
    push_remote = ""
    if args.push_source:
        if source_upstream:
            push_remote, upstream_branch = parse_upstream(source_upstream)
            push_target = upstream_branch or source_branch
            push_result = run_git(source_path, "push", push_remote, f"{source_branch}:{push_target}", check=False)
        else:
            push_remote = default_push_remote(source_path)
            if not push_remote:
                raise RuntimeError("Source branch has no upstream and no remote is configured; cannot push source branch")
            push_result = run_git(source_path, "push", "-u", push_remote, source_branch, check=False)
            source_upstream = branch_upstream(source_path, source_branch)
        if push_result.returncode != 0:
            raise RuntimeError(push_result.stderr.strip() or push_result.stdout.strip() or "git push failed")
        push_stdout = push_result.stdout.strip()

    return {
        "ok": True,
        "action": "merge-back",
        "sourceWorktreePath": str(source_path),
        "sourceBranch": source_branch,
        "mergedBranch": current_branch_name,
        "mergeStdout": result.stdout.strip(),
        "pushedSourceBranch": bool(args.push_source),
        "sourcePushRemote": push_remote,
        "sourceBranchUpstream": source_upstream,
        "sourcePushStdout": push_stdout,
    }


def command_cleanup(args: argparse.Namespace) -> dict[str, Any]:
    project_dir = Path(args.project).resolve()
    status = build_status(project_dir)
    if not status["isManagedWorktree"]:
        raise RuntimeError("Current project is not a qq-managed worktree")
    metadata = load_metadata(project_dir)
    pruned_runtime_paths = prune_copied_runtime_artifacts(project_dir, metadata.get("copiedLocalRuntimeFiles") or [])
    if pruned_runtime_paths:
        status = build_status(project_dir)
    if status["localChanges"] and not args.force:
        raise RuntimeError("Current worktree has local changes; pass --force to remove it anyway")
    if not args.force:
        if not status["sourceBranchMerged"]:
            raise RuntimeError("Current linked branch has not been merged back into the source branch; run merge-back first")
        if not status["sourceBranchPublished"]:
            raise RuntimeError("Source branch is not fully published upstream yet; push the source branch before cleanup")

    source_path = Path(str(status["sourceWorktreePath"]))
    current_path = Path(str(status["projectDir"]))
    current_branch_name = str(status["currentBranch"])
    if not source_path.is_dir():
        raise RuntimeError(f"Source worktree path not found: {source_path}")

    deleted_remote_branch = False
    remote_branch = ""
    remote_name = ""
    if args.delete_branch:
        current_upstream = branch_upstream(current_path, current_branch_name)
        if current_upstream:
            remote_name, remote_branch = parse_upstream(current_upstream)
        else:
            remote_name = default_push_remote(source_path)
            if remote_name and remote_branch_exists(source_path, remote_name, current_branch_name):
                remote_branch = current_branch_name
        if remote_name and remote_branch and remote_branch_exists(source_path, remote_name, remote_branch):
            delete_remote = run_git(source_path, "push", remote_name, "--delete", remote_branch, check=False)
            if delete_remote.returncode != 0:
                raise RuntimeError(delete_remote.stderr.strip() or delete_remote.stdout.strip() or "git push --delete failed")
            deleted_remote_branch = True

    remove_args = ["worktree", "remove"]
    if args.force or not status["localChanges"]:
        remove_args.append("--force")
    remove_args.append(str(current_path))
    run_git(source_path, *remove_args)

    branch_deleted = False
    if args.delete_branch:
        delete_args = ["branch", "-D" if args.force else "-d", current_branch_name]
        run_git(source_path, *delete_args)
        branch_deleted = True

    return {
        "ok": True,
        "action": "cleanup",
        "removedWorktreePath": str(current_path),
        "sourceWorktreePath": str(source_path),
        "prunedRuntimePaths": pruned_runtime_paths,
        "deletedBranch": branch_deleted,
        "deletedRemoteBranch": deleted_remote_branch,
        "branch": current_branch_name,
        "remoteName": remote_name,
        "remoteBranch": remote_branch,
    }


def command_closeout(args: argparse.Namespace) -> dict[str, Any]:
    project_dir = Path(args.project).resolve()
    initial_status = build_status(project_dir)
    if not initial_status["isManagedWorktree"]:
        raise RuntimeError("Current project is not a qq-managed worktree")
    if initial_status["localChanges"]:
        raise RuntimeError("Current worktree has uncommitted changes; commit or stash before closeout")

    merge_payload: dict[str, Any] | None = None
    if not initial_status["sourceBranchMerged"]:
        merge_args = argparse.Namespace(
            project=str(project_dir),
            auto_yes=args.auto_yes,
            push_source=True,
            pretty=args.pretty,
        )
        merge_payload = command_merge_back(merge_args)

    status_after_merge = build_status(project_dir)
    if not status_after_merge["canCleanup"]:
        raise RuntimeError(
            "Worktree is not ready for cleanup after merge-back; inspect qq-worktree status and publish the source branch if needed"
        )

    source_context_capsule = maybe_build_context_capsule(Path(str(status_after_merge["sourceWorktreePath"])), "worktree_handoff")

    cleanup_args = argparse.Namespace(
        project=str(project_dir),
        delete_branch=args.delete_branch,
        force=args.force,
        pretty=args.pretty,
    )
    cleanup_payload = command_cleanup(cleanup_args)
    return {
        "ok": True,
        "action": "closeout",
        "mergeBack": merge_payload,
        "sourceContextCapsule": source_context_capsule,
        "cleanup": cleanup_payload,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="qq worktree helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create", help="Create a qq-managed development worktree")
    create.add_argument("--project", default=".", help="Current project root")
    create.add_argument("--name", required=True, help="Task slug or human-readable worktree name")
    create.add_argument("--source-branch", default="", help="Source branch to branch off from")
    create.add_argument("--branch", default="", help="Explicit linked worktree branch name")
    create.add_argument("--path", default="", help="Explicit worktree path")
    create.add_argument("--base-dir", default="", help="Directory where sibling worktrees should be created")
    create.add_argument("--allow-main", action="store_true", help="Allow source branch main/master")
    create.add_argument("--allow-dirty-source", action="store_true", help="Allow creation even if the source worktree has local changes")
    create.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    status = subparsers.add_parser("status", help="Inspect current qq worktree context")
    status.add_argument("--project", default=".", help="Project root to inspect")
    status.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    seed_runtime_cache = subparsers.add_parser("seed-runtime-cache", help="Seed or refresh the current managed worktree runtime cache from its source worktree")
    seed_runtime_cache.add_argument("--project", default=".", help="Current worktree project root")
    seed_runtime_cache.add_argument("--refresh", action="store_true", help="Replace any existing local runtime cache before reseeding")
    seed_runtime_cache.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    merge_back = subparsers.add_parser("merge-back", help="Merge the current qq-managed worktree branch back into its source branch")
    merge_back.add_argument("--project", default=".", help="Current worktree project root")
    merge_back.add_argument("--auto-yes", action="store_true", help="Use non-interactive merge defaults")
    merge_back.add_argument("--push-source", action="store_true", help="Push the updated source branch after merge-back")
    merge_back.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    cleanup = subparsers.add_parser("cleanup", help="Remove the current qq-managed worktree from its source repository")
    cleanup.add_argument("--project", default=".", help="Current worktree project root")
    cleanup.add_argument("--delete-branch", action="store_true", help="Delete the linked branch after removing the worktree")
    cleanup.add_argument("--force", action="store_true", help="Force removal even if the worktree is dirty")
    cleanup.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    closeout = subparsers.add_parser("closeout", help="Merge back, publish source, and clean up the current qq-managed worktree")
    closeout.add_argument("--project", default=".", help="Current worktree project root")
    closeout.add_argument("--auto-yes", action="store_true", help="Use non-interactive merge defaults")
    closeout.add_argument("--delete-branch", action="store_true", help="Delete the linked branch after cleanup")
    closeout.add_argument("--force", action="store_true", help="Force cleanup if the current worktree is dirty")
    closeout.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "create":
            payload = command_create(args)
        elif args.command == "status":
            payload = command_status(args)
        elif args.command == "seed-runtime-cache":
            payload = command_seed_runtime_cache(args)
        elif args.command == "merge-back":
            payload = command_merge_back(args)
        elif args.command == "cleanup":
            payload = command_cleanup(args)
        elif args.command == "closeout":
            payload = command_closeout(args)
        else:
            raise RuntimeError(f"Unsupported command: {args.command}")
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if getattr(args, "pretty", False) else None, sort_keys=getattr(args, "pretty", False))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
