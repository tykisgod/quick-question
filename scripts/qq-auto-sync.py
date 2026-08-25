#!/usr/bin/env python3
"""Lightweight script-only sync after plugin upgrade. Runs at SessionStart[startup]."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

from qq_internal_git import apply_safe_git_hooks_fix


SCRIPT_DIR = Path(__file__).resolve().parent


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


class SyncPlanUnavailable(RuntimeError):
    """拿不到权威的安装计划。

    这个脚本每次会话启动都跑，同步结果直接落进消费方项目的 scripts/。
    拿不到计划时若自行猜一个（例如整目录扫描），猜错的代价是把不该发的脚本
    静默铺进项目：消费方要等到真正调用时才发现那是条死链路，故障被推迟到
    最难排查的时刻。宁可当场退非 0 把原因喊出来，也不要猜。
    """


def resolve_plan(plugin_root: Path, project_dir: Path) -> dict[str, Any]:
    helper = plugin_root / "scripts" / "qq_internal_install.py"
    if not helper.is_file():
        raise SyncPlanUnavailable(f"安装器不存在：{helper}")
    result = subprocess.run(
        [sys.executable, str(helper), "resolve", "--repo-root", str(plugin_root), "--project", str(project_dir)],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip() or "(无输出)"
        raise SyncPlanUnavailable(f"安装器 resolve 退出码 {result.returncode}：{detail}")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SyncPlanUnavailable(f"安装器 resolve 的输出不是合法 JSON：{exc}") from exc
    if not isinstance(payload, dict):
        raise SyncPlanUnavailable(f"安装器 resolve 的输出不是 JSON 对象，而是 {type(payload).__name__}")
    return payload


def sync_scripts(plugin_root: Path, project_dir: Path, entries: list[dict[str, str]]) -> list[str]:
    synced: list[str] = []
    for entry in entries:
        target_rel = entry.get("target", "")
        source_rel = entry.get("source", "")
        target_normalized = target_rel.replace("\\", "/")
        if not target_normalized.startswith("scripts/"):
            continue

        source = plugin_root / source_rel
        target = project_dir / target_rel
        if not source.is_file():
            continue

        target.parent.mkdir(parents=True, exist_ok=True)
        needs_copy = not target.is_file()
        if not needs_copy:
            needs_copy = source.stat().st_size != target.stat().st_size
        if not needs_copy:
            needs_copy = source.read_bytes() != target.read_bytes()
        if not needs_copy:
            continue

        shutil.copy2(str(source), str(target))
        if target_rel.endswith((".sh", ".py")):
            try:
                target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            except OSError:
                pass
        synced.append(target_rel)
    return synced


def run(project_dir: Path, plugin_root: Path) -> int:
    # Repair the silently-broken core.hooksPath configuration if present.
    # Only acts when the local config points at the default .git/hooks/ — never
    # touches global/system git config or user-chosen custom hook directories.
    git_hooks_fix = apply_safe_git_hooks_fix(project_dir)
    if git_hooks_fix:
        previous = git_hooks_fix.get("previousValue") or "(unset)"
        print(f"[qq] Repaired core.hooksPath (was {previous}) → {git_hooks_fix['command']}")

    install_state_path = project_dir / ".qq" / "install-state.json"
    state = load_json(install_state_path)
    if not state:
        if not (project_dir / ".qq").is_dir():
            return 0
        state = {"pluginVersion": "", "managedFiles": []}

    plugin_manifest_path = plugin_root / ".claude-plugin" / "plugin.json"
    plugin_json = load_json(plugin_manifest_path)
    plugin_version = str(plugin_json.get("version") or "")
    # 版本读不出来时旧代码直接 return 0，"读不到清单"与"版本没变、无事可做"
    # 走同一条静默出口，插件坏了也永远同步不到，而且一声不吭。
    if not plugin_version:
        raise SyncPlanUnavailable(f"读不出插件版本：{plugin_manifest_path}")

    installed_version = str(state.get("pluginVersion") or "")
    if plugin_version == installed_version:
        return 0

    # selectedModules 是"这个项目装了哪些模块"的唯一权威记录。它缺失时旧代码会
    # 退化成把 plugin 的 scripts/ 整个目录 rglob 一遍全量铺过去——这会绕过安装器
    # 刻意做的模块取舍（例如 tykit 已从 engine-unity 模块移除，全量铺又会把
    # tykit_* 送回项目），把安装器的决定悄悄推翻。宁可让用户重跑一次安装器。
    if not state.get("selectedModules"):
        raise SyncPlanUnavailable(
            f"{install_state_path} 里没有 selectedModules，无从判断该项目装了哪些模块；"
            "请在该项目重跑 qq 的 install.sh 重建安装状态"
        )

    plan = resolve_plan(plugin_root, project_dir)
    entries = plan.get("entries") or []
    if not entries:
        return 0

    synced = sync_scripts(plugin_root, project_dir, entries)

    if synced:
        existing_managed = set(state.get("managedFiles") or [])
        existing_managed.update(synced)
        state["managedFiles"] = sorted(existing_managed)

    state["pluginVersion"] = plugin_version
    save_json(install_state_path, state)

    if synced:
        print(f"[qq] Synced {len(synced)} script(s) (v{installed_version} → v{plugin_version})")

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="qq auto-sync: sync project scripts after plugin upgrade")
    parser.add_argument("--project", required=True, help="Project root")
    parser.add_argument("--plugin-root", required=True, help="Plugin cache root (CLAUDE_PLUGIN_ROOT)")
    args = parser.parse_args()

    try:
        return run(Path(args.project).resolve(), Path(args.plugin_root).resolve())
    except SyncPlanUnavailable as exc:
        print(f"[qq] 脚本同步已中止：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
