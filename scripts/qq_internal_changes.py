#!/usr/bin/env python3
from __future__ import annotations

import hashlib
from pathlib import Path

from qq_internal_git import resolve_git_context, run_git


IGNORED_STATUS_PREFIXES = (
    ".qq/",
)
STATIC_IGNORED_STATUS_PATHS = {
    ".qq",
    ".qq/local.yaml",
    ".mcp.json",
    ".claude/settings.local.json",
    "qq.yaml",
}
IGNORED_STATUS_SEGMENTS = {
    "__pycache__",
}
IGNORED_STATUS_SUFFIXES = (
    ".pyc",
    ".pyo",
)


def normalize_status_path(raw: str) -> str:
    path = raw.strip()
    if " -> " in path:
        path = path.split(" -> ", 1)[1].strip()
    return Path(path).as_posix()


def is_ignored_status_path(relative_path: str) -> bool:
    normalized = normalize_status_path(relative_path).rstrip("/")
    if normalized in STATIC_IGNORED_STATUS_PATHS:
        return True
    if any(normalized.startswith(prefix) for prefix in IGNORED_STATUS_PREFIXES):
        return True
    parts = [part for part in Path(normalized).parts if part not in {"."}]
    if any(part in IGNORED_STATUS_SEGMENTS for part in parts):
        return True
    if normalized.endswith(IGNORED_STATUS_SUFFIXES):
        return True
    return False


def meaningful_local_change_paths(project_dir: Path) -> list[str]:
    result = run_git(project_dir, "status", "--porcelain", check=False)
    if result.returncode != 0:
        return []

    paths: set[str] = set()
    for raw in result.stdout.splitlines():
        line = raw.rstrip()
        if len(line) < 4:
            continue
        relative_path = normalize_status_path(line[3:])
        if not relative_path or is_ignored_status_path(relative_path):
            continue
        paths.add(relative_path)
    return sorted(paths)


def file_content_digest(path: Path) -> str:
    if not path.exists() or not path.is_file():
        return "missing"
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def meaningful_local_change_snapshot(project_dir: Path) -> dict[str, object]:
    result = run_git(project_dir, "status", "--porcelain", check=False)
    if result.returncode != 0:
        return {"paths": [], "fingerprint": ""}

    entries: list[str] = []
    paths: list[str] = []
    for raw in result.stdout.splitlines():
        line = raw.rstrip()
        if len(line) < 4:
            continue
        status = line[:2]
        relative_path = normalize_status_path(line[3:])
        if not relative_path or is_ignored_status_path(relative_path):
            continue
        content_digest = file_content_digest(project_dir / relative_path)
        entries.append(f"{status} {relative_path} {content_digest}")
        paths.append(relative_path)

    payload = "\n".join(sorted(entries)).encode("utf-8")
    fingerprint = hashlib.sha256(payload).hexdigest() if entries else ""
    return {"paths": sorted(set(paths)), "fingerprint": fingerprint}


def latest_change_mtime(project_dir: Path, changed_files: list[str]) -> float | None:
    latest: float | None = None
    for relative in changed_files:
        path = project_dir / relative
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        latest = mtime if latest is None else max(latest, mtime)
    return latest


def git_head(project_dir: Path) -> str:
    """当前提交的 sha；不在 git 里或还没有提交时是空串。"""
    result = run_git(project_dir, "rev-parse", "--verify", "--quiet", "HEAD", check=False)
    return result.stdout.strip() if result.returncode == 0 else ""


def engine_changes_since(project_dir: Path, patterns: list[str], base: str) -> dict[str, str] | None:
    """工作区里和 base 提交不一样的引擎文件 → 内容摘要（删掉的记 missing）。

    已提交和没提交的改动一起算：拿检查时的 HEAD 当 base，查完原样提交，结果和查的时候一样；
    查完又改、改了再提交、删掉文件，结果都会变。base 为空（还没有提交）只算未跟踪的文件。
    git 认不出 base（提交被改写掉了）返回 None；不在 git 里也返回 None。
    """
    if not patterns:
        return {}
    files: set[str] = set()
    if base:
        diff = run_git(project_dir, "diff", "--name-only", "--no-renames", "--relative", "-z", base, "--", *patterns, check=False)
        if diff.returncode != 0:
            return None
        files.update(path for path in diff.stdout.split("\0") if path)
    untracked = run_git(project_dir, "ls-files", "--others", "--exclude-standard", "-z", "--", *patterns, check=False)
    if untracked.returncode != 0:
        return None
    files.update(path for path in untracked.stdout.split("\0") if path)
    root = resolve_git_context(project_dir).cwd
    return {path: file_content_digest(root / path) for path in sorted(files)}
