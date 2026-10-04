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
import time
from pathlib import Path
from typing import Any

from qq_internal_git import apply_safe_git_hooks_fix


SCRIPT_DIR = Path(__file__).resolve().parent


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return value if isinstance(value, dict) else {}


def save_json(path: Path, value: dict[str, Any]) -> None:
    # 先写同目录的临时文件再 os.replace 换上去：直接截断重写时，同一项目里同时启动的
    # 另一个会话可能恰好读到空文件或半截文件。
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with tmp.open("w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        for attempt in range(20):
            try:
                os.replace(tmp, path)
                break
            except PermissionError:
                # Windows 上目标正被别的进程开着（例如另一个会话在读）时换不上去，稍等再试
                if attempt == 19:
                    raise
                time.sleep(0.05)
    finally:
        tmp.unlink(missing_ok=True)


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


def read_install_state(path: Path) -> dict[str, Any]:
    """读已存在的 install-state.json；读不出合法的 JSON 对象就报错，绝不当成空状态。

    读失败若跟「老状态缺 selectedModules」走同一条路，下面的补全会拿默认选择把整份
    文件写回去，里面真实的 selectedModules、managedFiles、engine 就丢了；managedFiles 一丢，
    install.sh --sync 按差集清理孤儿文件也跟着失效。所以只报错、不写。UTF-8 BOM
    （PowerShell 5.1 的 Set-Content -Encoding UTF8 会加）照常认。
    """
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        reason = f"{type(exc).__name__}: {exc}"
    else:
        if isinstance(value, dict):
            return value
        reason = f"顶层是 {type(value).__name__}，不是 JSON 对象"
    raise SyncPlanUnavailable(
        f"读不出安装状态 {path}（{reason}）；为免覆盖其中的 selectedModules/managedFiles，"
        "本次不同步也不改写它，请把它修成 UTF-8 编码的 JSON 对象"
    )


def backfill_install_state(state: dict[str, Any], plan: dict[str, Any]) -> None:
    """给缺 selectedModules 的老安装状态补一次。

    1.18.0 之前，自动同步碰到没有安装状态的项目会自己建一份，里面只有 pluginVersion 和
    managedFiles。为补一个字段让人重跑 install.sh 代价太大（它会覆盖项目里的文件），所以
    就地补：字段对齐 install.sh 写的形状，已有的字段（managedFiles、pluginVersion 等）原样保留。

    selectedModules 直接取这次同步要铺的计划（resolve 的默认选择），不拿 managedFiles 反推：
    紧接着的同步会把计划里每个模块的脚本都铺进项目并记进 managedFiles，反推出的子集会跟
    同一次运行装下的文件互相矛盾（doctor 一直报模块缺失，补过一次后又不会再重算）。老状态的
    managedFiles 本来也只记了当次升级缺的或改过的文件，反推不出全貌。
    """
    modules = [str(module) for module in plan.get("selectedModules") or []]
    if not modules:
        raise SyncPlanUnavailable("安装器 resolve 给出的模块选择为空，无从补全安装状态里的 selectedModules")

    state["selectedModules"] = modules
    state.setdefault("engine", str(plan.get("engine") or ""))
    state.setdefault("profile", str(plan.get("profile") or ""))
    state.setdefault("defaultModules", list(plan.get("defaultModules") or []))
    state.setdefault("requiredModules", list(plan.get("requiredModules") or []))
    state.setdefault("hosts", list(plan.get("hosts") or []))
    state.setdefault("managedFiles", [])
    state.setdefault("syncEnabled", bool(plan.get("sync")))
    state.setdefault("removedFiles", [])


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
    # 没有安装状态就当没装过。.qq/ 本身不说明装过 qq：git worktree 里常常只放一份
    # .qq/local.yaml 配置，旧代码把它当成「装过、版本号为空」，接着又因缺 selectedModules
    # 报错，每开一次会话就报一次。
    if not install_state_path.is_file():
        return 0
    state = read_install_state(install_state_path)

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

    plan = resolve_plan(plugin_root, project_dir)

    # selectedModules 是"这个项目装了哪些模块"的唯一权威记录。老状态缺它时不能退回
    # 整目录 rglob 全量铺（会绕过安装器的模块取舍，例如把已移除的 tykit_* 送回项目），
    # 也不该为补一个字段让人重跑 install.sh。按这次要铺的计划就地补一次并立刻写回，
    # 之后版本没变就照常静默退出。
    if not state.get("selectedModules"):
        backfill_install_state(state, plan)
        save_json(install_state_path, state)
        print(
            "[qq] Backfilled selectedModules in .qq/install-state.json from the install plan this sync applies: "
            + ", ".join(state["selectedModules"])
        )

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
