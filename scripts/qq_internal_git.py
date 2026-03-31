#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


@dataclass(frozen=True)
class GitContext:
    project_dir: Path
    work_tree_root: Path
    git_dir: Path | None
    use_explicit_work_tree: bool

    def command(self, *args: str) -> list[str]:
        command = ["git"]
        if self.use_explicit_work_tree and self.git_dir is not None:
            command.extend(
                [
                    f"--git-dir={self.git_dir}",
                    f"--work-tree={self.work_tree_root}",
                ]
            )
        command.extend(args)
        return command

    @property
    def cwd(self) -> Path:
        return self.work_tree_root if self.use_explicit_work_tree else self.project_dir


def _run_plain_git(project_dir: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=project_dir,
        check=False,
        capture_output=True,
        text=True,
    )


def _discover_work_tree_root(project_dir: Path) -> Path | None:
    for candidate in [project_dir, *project_dir.parents]:
        if (candidate / ".git").exists():
            return candidate
    return None


def _resolve_git_dir(project_dir: Path, fallback_root: Path | None) -> Path | None:
    result = _run_plain_git(project_dir, "rev-parse", "--git-dir")
    raw = result.stdout.strip()
    if result.returncode == 0 and raw:
        path = Path(raw)
        if not path.is_absolute():
            path = (project_dir / path).resolve()
        else:
            path = path.resolve()
        return path
    if fallback_root is not None and (fallback_root / ".git").exists():
        return (fallback_root / ".git").resolve()
    return None


@lru_cache(maxsize=32)
def resolve_git_context(project_dir: str | Path) -> GitContext:
    project_path = Path(project_dir).resolve()
    discovered_root = _discover_work_tree_root(project_path) or project_path

    bare_result = _run_plain_git(project_path, "config", "--bool", "--get", "core.bare")
    is_bare = bare_result.returncode == 0 and bare_result.stdout.strip().lower() == "true"

    if is_bare:
        git_dir = _resolve_git_dir(project_path, discovered_root)
        return GitContext(
            project_dir=project_path,
            work_tree_root=discovered_root,
            git_dir=git_dir,
            use_explicit_work_tree=True,
        )

    top_level = _run_plain_git(project_path, "rev-parse", "--show-toplevel")
    work_tree_root = discovered_root
    if top_level.returncode == 0 and top_level.stdout.strip():
        work_tree_root = Path(top_level.stdout.strip()).resolve()

    git_dir = _resolve_git_dir(project_path, work_tree_root)
    return GitContext(
        project_dir=project_path,
        work_tree_root=work_tree_root,
        git_dir=git_dir,
        use_explicit_work_tree=False,
    )


def run_git(project_dir: str | Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    context = resolve_git_context(project_dir)
    result = subprocess.run(
        context.command(*args),
        cwd=context.cwd,
        check=False,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "git command failed")
    return result


def repo_root(project_dir: str | Path) -> Path:
    return resolve_git_context(project_dir).work_tree_root
