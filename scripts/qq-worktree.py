#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


METADATA_VERSION = 1
MANAGED_BY = "qq"
PROTECTED_SOURCE_BRANCHES = {"main", "master"}
LOCAL_RUNTIME_FILES = [
    ".mcp.json",
    ".claude/settings.local.json",
]
IGNORED_STATUS_PREFIXES = (
    ".qq/",
)
IGNORED_STATUS_PATHS = {
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


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def run_git(project_dir: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=project_dir,
        check=False,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "git command failed")
    return result


def repo_root(project_dir: Path) -> Path:
    result = run_git(project_dir, "rev-parse", "--show-toplevel")
    return Path(result.stdout.strip()).resolve()


def current_branch(project_dir: Path) -> str:
    result = run_git(project_dir, "rev-parse", "--abbrev-ref", "HEAD")
    branch = result.stdout.strip()
    if not branch or branch == "HEAD":
        raise RuntimeError("Detached HEAD is not supported for qq-managed worktree creation")
    return branch


def current_commit(project_dir: Path) -> str:
    result = run_git(project_dir, "rev-parse", "HEAD")
    return result.stdout.strip()


def relevant_status_lines(project_dir: Path) -> list[str]:
    result = run_git(project_dir, "status", "--porcelain", check=False)
    if result.returncode != 0:
        return ["__git_status_failed__"]
    lines: list[str] = []
    for raw in result.stdout.splitlines():
        line = raw.rstrip()
        path = line[3:] if len(line) > 3 else ""
        if should_ignore_status_path(project_dir, path):
            continue
        lines.append(line)
    return lines


def is_ignored_runtime_leaf(path: Path, project_dir: Path) -> bool:
    try:
        relative = path.relative_to(project_dir).as_posix()
    except ValueError:
        relative = path.as_posix()
    if relative in IGNORED_STATUS_PATHS:
        return True
    if any(relative.startswith(prefix) for prefix in IGNORED_STATUS_PREFIXES):
        return True
    parts = [part for part in Path(relative).parts if part not in {"."}]
    if any(part in IGNORED_STATUS_SEGMENTS for part in parts):
        return True
    if relative.endswith(IGNORED_STATUS_SUFFIXES):
        return True
    return False


def should_ignore_status_path(project_dir: Path, relative_path: str) -> bool:
    candidate = project_dir / relative_path
    if is_ignored_runtime_leaf(candidate, project_dir):
        return True
    if candidate.is_dir():
        try:
            descendants = list(candidate.rglob("*"))
        except OSError:
            return False
        if descendants and all(is_ignored_runtime_leaf(descendant, project_dir) for descendant in descendants):
            return True
    return False


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


def copy_local_runtime_files(source_dir: Path, target_dir: Path) -> list[str]:
    copied: list[str] = []
    for relative in LOCAL_RUNTIME_FILES:
        src = source_dir / relative
        if not src.is_file():
            continue
        dst = target_dir / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied.append(relative)
    return copied


def build_status(project_dir: Path) -> dict[str, Any]:
    root = repo_root(project_dir)
    branch = current_branch(root)
    metadata = load_metadata(root)
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
    source_clean = bool(source_worktree and source_exists and is_clean_worktree(source_worktree))
    payload = {
        "projectDir": str(root),
        "currentBranch": branch,
        "currentCommit": current_commit(root),
        "isManagedWorktree": managed,
        "role": "managed" if managed else "primary",
        "worktreeName": str(metadata.get("worktreeName") or ""),
        "sourceBranch": str(metadata.get("sourceBranch") or ""),
        "sourceWorktreePath": str(source_worktree) if source_worktree else "",
        "sourceWorktreeExists": source_exists,
        "sourceWorktreeClean": source_clean if source_exists else False,
        "metadataPath": str(metadata_path(root)),
        "localChanges": not is_clean_worktree(root),
        "worktrees": worktrees,
    }
    payload["canMergeBack"] = managed and not payload["localChanges"] and source_exists and source_clean and branch != payload["sourceBranch"]
    payload["canCleanup"] = managed and not payload["localChanges"] and source_exists and branch != payload["sourceBranch"]
    return payload


def ensure_branch_missing(project_dir: Path, branch: str) -> None:
    result = run_git(project_dir, "show-ref", "--verify", f"refs/heads/{branch}", check=False)
    if result.returncode == 0:
        raise RuntimeError(f"Branch already exists: {branch}")


def command_create(args: argparse.Namespace) -> dict[str, Any]:
    project_dir = Path(args.project).resolve()
    root = repo_root(project_dir)
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
    metadata = {
        "managedBy": MANAGED_BY,
        "metadataVersion": METADATA_VERSION,
        "createdAt": utc_now_iso(),
        "worktreeName": slug,
        "branch": branch,
        "sourceBranch": source_branch,
        "sourceWorktreePath": str(root),
        "currentPath": str(target_path),
        "copiedLocalRuntimeFiles": copied_files,
    }
    metadata_file = write_metadata(target_path, metadata)
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
    }


def command_status(args: argparse.Namespace) -> dict[str, Any]:
    payload = build_status(Path(args.project).resolve())
    payload["ok"] = True
    payload["action"] = "status"
    return payload


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

    run_git(source_path, "checkout", source_branch)
    merge_args = ["merge", "--no-ff"]
    if args.auto_yes:
        merge_args.append("--no-edit")
    merge_args.append(current_branch_name)
    result = run_git(source_path, *merge_args, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "git merge failed")

    return {
        "ok": True,
        "action": "merge-back",
        "sourceWorktreePath": str(source_path),
        "sourceBranch": source_branch,
        "mergedBranch": current_branch_name,
        "mergeStdout": result.stdout.strip(),
    }


def command_cleanup(args: argparse.Namespace) -> dict[str, Any]:
    project_dir = Path(args.project).resolve()
    status = build_status(project_dir)
    if not status["isManagedWorktree"]:
        raise RuntimeError("Current project is not a qq-managed worktree")
    if status["localChanges"] and not args.force:
        raise RuntimeError("Current worktree has local changes; pass --force to remove it anyway")

    source_path = Path(str(status["sourceWorktreePath"]))
    current_path = Path(str(status["projectDir"]))
    current_branch_name = str(status["currentBranch"])
    if not source_path.is_dir():
        raise RuntimeError(f"Source worktree path not found: {source_path}")

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
        "deletedBranch": branch_deleted,
        "branch": current_branch_name,
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

    merge_back = subparsers.add_parser("merge-back", help="Merge the current qq-managed worktree branch back into its source branch")
    merge_back.add_argument("--project", default=".", help="Current worktree project root")
    merge_back.add_argument("--auto-yes", action="store_true", help="Use non-interactive merge defaults")
    merge_back.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    cleanup = subparsers.add_parser("cleanup", help="Remove the current qq-managed worktree from its source repository")
    cleanup.add_argument("--project", default=".", help="Current worktree project root")
    cleanup.add_argument("--delete-branch", action="store_true", help="Delete the linked branch after removing the worktree")
    cleanup.add_argument("--force", action="store_true", help="Force removal even if the worktree is dirty")
    cleanup.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "create":
            payload = command_create(args)
        elif args.command == "status":
            payload = command_status(args)
        elif args.command == "merge-back":
            payload = command_merge_back(args)
        elif args.command == "cleanup":
            payload = command_cleanup(args)
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
