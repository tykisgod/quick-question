#!/usr/bin/env python3
"""qq-preflight.py — 项目就绪性检查

在执行任何引擎源代码写入前验证项目可以编译。
输出结构化 JSON，供 skill 和 hook 消费。

用法:
  qq-preflight.py --project /path/to/project --pretty
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def check_unity(project_dir: Path) -> dict[str, Any]:
    checks: dict[str, Any] = {}

    # ── ProjectSettings/ProjectVersion.txt ──
    version_file = project_dir / "ProjectSettings" / "ProjectVersion.txt"
    checks["has_project_version"] = version_file.is_file()

    # ── Packages/manifest.json ──
    # 只读诊断：包依赖归项目自己管。qq 曾在这里代写 manifest（注入 tykit），
    # 那等于在用户项目里塞一条它没声明过的依赖——tykit 退役后这条路径连带删除，
    # preflight 不再写任何项目文件。
    checks["has_manifest"] = (project_dir / "Packages" / "manifest.json").is_file()

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
    else:
        checks["ready"] = True
        checks["block_reason"] = ""
        checks["message"] = "Project is ready for compilation."

    return checks


def check_godot(project_dir: Path) -> dict[str, Any]:
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

    return checks


def check_unreal(project_dir: Path) -> dict[str, Any]:
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

    return checks


def check_sbox(project_dir: Path) -> dict[str, Any]:
    checks: dict[str, Any] = {}
    checks["ready"] = True
    checks["block_reason"] = ""
    checks["message"] = "Project is ready."
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


def run_preflight(project_dir: Path) -> dict[str, Any]:
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
        return result

    checker = ENGINE_CHECKERS[engine]
    checks = checker(project_dir)
    result["ready"] = checks.pop("ready")
    result["block_reason"] = checks.pop("block_reason")
    result["message"] = checks.pop("message")
    result["checks"] = checks
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="qq project preflight check")
    parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON")
    args = parser.parse_args()

    project_dir = Path(args.project).resolve()
    result = run_preflight(project_dir)
    print(json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None))
    return 0 if result["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
