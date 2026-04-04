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


def resolve_plan(plugin_root: Path, project_dir: Path) -> dict[str, Any]:
    helper = plugin_root / "scripts" / "qq_internal_install.py"
    if not helper.is_file():
        return {}
    result = subprocess.run(
        [sys.executable, str(helper), "resolve", "--repo-root", str(plugin_root), "--project", str(project_dir)],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        return {}
    try:
        payload = json.loads(result.stdout)
        return payload if isinstance(payload, dict) else {}
    except Exception:
        return {}


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


def main() -> int:
    parser = argparse.ArgumentParser(description="qq auto-sync: sync project scripts after plugin upgrade")
    parser.add_argument("--project", required=True, help="Project root")
    parser.add_argument("--plugin-root", required=True, help="Plugin cache root (CLAUDE_PLUGIN_ROOT)")
    args = parser.parse_args()

    project_dir = Path(args.project).resolve()
    plugin_root = Path(args.plugin_root).resolve()

    install_state_path = project_dir / ".qq" / "install-state.json"
    state = load_json(install_state_path)
    if not state:
        if not (project_dir / ".qq").is_dir():
            return 0
        state = {"pluginVersion": "", "managedFiles": []}

    plugin_json = load_json(plugin_root / ".claude-plugin" / "plugin.json")
    plugin_version = str(plugin_json.get("version") or "")
    installed_version = str(state.get("pluginVersion") or "")

    if not plugin_version or plugin_version == installed_version:
        return 0

    has_full_state = bool(state.get("selectedModules"))

    if has_full_state:
        plan = resolve_plan(plugin_root, project_dir)
        entries = plan.get("entries") or []
    else:
        entries = []
        scripts_dir = plugin_root / "scripts"
        if scripts_dir.is_dir():
            for path in sorted(scripts_dir.rglob("*")):
                if path.is_file():
                    rel = str(path.relative_to(plugin_root)).replace("\\", "/")
                    entries.append({"source": rel, "target": rel})

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


if __name__ == "__main__":
    sys.exit(main())
