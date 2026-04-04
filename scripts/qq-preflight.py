#!/usr/bin/env python3
"""qq-preflight.py — 项目就绪性检查 + 自动修复

在执行任何引擎源代码写入前验证项目可以编译。
输出结构化 JSON，供 skill 和 hook 消费。

用法:
  qq-preflight.py --project /path/to/project --pretty
  qq-preflight.py --project /path/to/project --fix --pretty
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

TYKIT_REF = "https://github.com/tykisgod/tykit.git#84b129b026d3b725f5f7dd21d59a5fe9d206850c"

UNITY_MINIMAL_MANIFEST = {
    "dependencies": {
        "com.tyk.tykit": TYKIT_REF,
    },
}


def check_unity(project_dir: Path, fix: bool) -> dict[str, Any]:
    checks: dict[str, Any] = {}
    fixes_applied: list[str] = []

    # ── ProjectSettings/ProjectVersion.txt ──
    version_file = project_dir / "ProjectSettings" / "ProjectVersion.txt"
    checks["has_project_version"] = version_file.is_file()

    # ── Packages/manifest.json + tykit ──
    manifest_path = project_dir / "Packages" / "manifest.json"
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            manifest = {}
        deps = manifest.get("dependencies") or {}
        has_tykit = "com.tyk.tykit" in deps
        checks["has_manifest"] = True
        checks["has_tykit"] = has_tykit
        checks["tykit_ref"] = str(deps.get("com.tyk.tykit", ""))

        if not has_tykit and fix:
            if not isinstance(manifest.get("dependencies"), dict):
                manifest["dependencies"] = {}
            manifest["dependencies"]["com.tyk.tykit"] = TYKIT_REF
            manifest_path.write_text(
                json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            checks["has_tykit"] = True
            checks["tykit_ref"] = TYKIT_REF
            fixes_applied.append("tykit_added_to_manifest")
    else:
        checks["has_manifest"] = False
        checks["has_tykit"] = False
        checks["tykit_ref"] = ""

        if fix:
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_text(
                json.dumps(UNITY_MINIMAL_MANIFEST, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            checks["has_manifest"] = True
            checks["has_tykit"] = True
            checks["tykit_ref"] = TYKIT_REF
            fixes_applied.append("manifest_created_with_tykit")

    # ── Library/ ──
    checks["has_library"] = (project_dir / "Library").is_dir()

    # ── Temp/tykit.json ──
    tykit_json = project_dir / "Temp" / "tykit.json"
    checks["has_tykit_json"] = tykit_json.is_file()
    if tykit_json.is_file():
        try:
            tykit_data = json.loads(tykit_json.read_text(encoding="utf-8"))
            checks["tykit_port"] = tykit_data.get("port", 0)
        except (json.JSONDecodeError, OSError):
            checks["tykit_port"] = 0
    else:
        checks["tykit_port"] = 0

    # ── Overall readiness ──
    if not checks["has_library"]:
        checks["ready"] = False
        checks["block_reason"] = "virgin_project"
        checks["message"] = (
            "Library/ does not exist — Unity has never opened this project. "
            "Open in Unity Hub, wait for import to complete, then retry."
        )
    elif not checks["has_tykit"]:
        checks["ready"] = False
        checks["block_reason"] = "missing_tykit"
        checks["message"] = (
            "com.tyk.tykit is not in Packages/manifest.json. "
            "Run with --fix to auto-inject, or add manually."
        )
    else:
        checks["ready"] = True
        checks["block_reason"] = ""
        checks["message"] = "Project is ready for compilation."

    checks["fixes_applied"] = fixes_applied
    return checks


def check_godot(project_dir: Path, fix: bool) -> dict[str, Any]:
    checks: dict[str, Any] = {}
    checks["has_godot_dir"] = (project_dir / ".godot").is_dir()
    checks["has_project_godot"] = (project_dir / "project.godot").is_file()

    if not checks["has_godot_dir"]:
        checks["ready"] = False
        checks["block_reason"] = "virgin_project"
        checks["message"] = (
            ".godot/ does not exist — Godot has never opened this project. "
            "Open in Godot Editor first."
        )
    else:
        checks["ready"] = True
        checks["block_reason"] = ""
        checks["message"] = "Project is ready."

    checks["fixes_applied"] = []
    return checks


def check_unreal(project_dir: Path, fix: bool) -> dict[str, Any]:
    checks: dict[str, Any] = {}
    checks["has_intermediate"] = (project_dir / "Intermediate").is_dir()

    if not checks["has_intermediate"]:
        checks["ready"] = False
        checks["block_reason"] = "virgin_project"
        checks["message"] = (
            "Intermediate/ does not exist — Unreal Editor has never opened this project. "
            "Open in Unreal Editor first."
        )
    else:
        checks["ready"] = True
        checks["block_reason"] = ""
        checks["message"] = "Project is ready."

    checks["fixes_applied"] = []
    return checks


def check_sbox(project_dir: Path, fix: bool) -> dict[str, Any]:
    checks: dict[str, Any] = {}
    checks["ready"] = True
    checks["block_reason"] = ""
    checks["message"] = "Project is ready."
    checks["fixes_applied"] = []
    return checks


def detect_engine(project_dir: Path) -> str:
    """Lightweight engine detection without importing qq_engine."""
    if (project_dir / "ProjectSettings" / "ProjectVersion.txt").is_file():
        return "unity"
    if (project_dir / "project.godot").is_file():
        return "godot"
    if any(project_dir.glob("*.uproject")):
        return "unreal"
    if any(project_dir.glob("*.sbproj")) or (project_dir / ".sbproj").is_file():
        return "sbox"
    return ""


ENGINE_CHECKERS = {
    "unity": check_unity,
    "godot": check_godot,
    "unreal": check_unreal,
    "sbox": check_sbox,
}


def run_preflight(project_dir: Path, fix: bool) -> dict[str, Any]:
    engine = detect_engine(project_dir)
    result: dict[str, Any] = {
        "project_dir": str(project_dir),
        "engine": engine,
    }

    if not engine:
        result["ready"] = False
        result["block_reason"] = "no_engine"
        result["message"] = f"{project_dir} is not a recognized engine project."
        result["checks"] = {}
        result["fixes_applied"] = []
        return result

    checker = ENGINE_CHECKERS[engine]
    checks = checker(project_dir, fix)
    result["ready"] = checks.pop("ready")
    result["block_reason"] = checks.pop("block_reason")
    result["message"] = checks.pop("message")
    result["fixes_applied"] = checks.pop("fixes_applied")
    result["checks"] = checks
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="qq project preflight check")
    parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON")
    parser.add_argument("--fix", action="store_true", help="Auto-fix recoverable issues (e.g. inject tykit)")
    args = parser.parse_args()

    project_dir = Path(args.project).resolve()
    result = run_preflight(project_dir, fix=args.fix)
    print(json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None))
    return 0 if result["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
