#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from pathlib import Path
from typing import Any


ENGINE_DEFINITIONS: dict[str, dict[str, Any]] = {
    "unity": {
        "displayName": "Unity",
        "projectMarkers": ["ProjectSettings/ProjectVersion.txt"],
        "sourcePatterns": ["*.cs"],
        "verificationPatterns": ["*.cs"],
        "runtimeCacheDir": "Library",
        "runtimeCacheSupportDir": "PackageCache",
        "bridgeScript": "qq_mcp.py",
        "bridgeBackend": "tykit",
        "bridgeServerName": "qq-unity",
        "bridgeHostStateFile": "qq-unity-mcp-host.json",
        "codexServerPrefix": "qq-unity-",
        "defaultSlug": "unity-project",
        "defaultEnabledRules": [
            "find_object_of_type",
            "send_message",
            "tag_compare",
            "get_component_in_hot_path",
        ],
        "defaultTestScopes": {
            "core": "editmode",
            "feature": "all",
            "hardening": "all",
        },
        "hostValidationReason": "Unity validation should stay on the host machine for this project.",
        "recommendedCompileAction": "./scripts/qq-compile.sh",
    },
    "godot": {
        "displayName": "Godot",
        "projectMarkers": ["project.godot"],
        "sourcePatterns": ["*.gd", "*.cs", "*.gdshader", "*.gdshaderinc"],
        "verificationPatterns": [
            "*.gd",
            "*.cs",
            "*.gdshader",
            "*.gdshaderinc",
            "*.tscn",
            "*.scn",
            "*.tres",
            "*.res",
            "project.godot",
        ],
        "runtimeCacheDir": ".godot",
        "runtimeCacheSupportDir": "imported",
        "bridgeScript": "qq_mcp.py",
        "bridgeBackend": "qq-godot-editor",
        "bridgeServerName": "qq-godot",
        "bridgeHostStateFile": "qq-godot-mcp-host.json",
        "codexServerPrefix": "qq-godot-",
        "defaultSlug": "godot-project",
        "editorBridgeStateFile": ".qq/state/qq-godot-editor-bridge.json",
        "editorBridgeRequestDir": ".qq/state/qq-godot-editor/requests",
        "editorBridgeResponseDir": ".qq/state/qq-godot-editor/responses",
        "editorBridgeConsoleFile": ".qq/state/qq-godot-editor-console.jsonl",
        "editorPluginName": "qq_editor_bridge",
        "editorPluginConfigPath": "res://addons/qq_editor_bridge/plugin.cfg",
        "engineSupportSourceDir": "engines/godot/addons/qq_editor_bridge",
        "engineSupportTargetDir": "addons/qq_editor_bridge",
        "defaultEnabledRules": [
            "get_node_in_hot_path",
            "group_scan_in_hot_path",
        ],
        "defaultTestScopes": {
            "core": "all",
            "feature": "all",
            "hardening": "all",
        },
        "hostValidationReason": "Godot project validation is engine-local and should run against the project on the host machine.",
        "recommendedCompileAction": "./scripts/qq-compile.sh",
    },
}


def normalize_engine_id(value: Any) -> str:
    return str(value or "").strip().lower()


def known_engines() -> list[str]:
    return sorted(ENGINE_DEFINITIONS.keys())


def engine_metadata(engine: str) -> dict[str, Any]:
    normalized = normalize_engine_id(engine)
    payload = ENGINE_DEFINITIONS.get(normalized) or {}
    return json.loads(json.dumps(payload))


def is_engine_project(project_dir: Path, engine: str) -> bool:
    metadata = engine_metadata(engine)
    if not metadata:
        return False
    for marker in metadata.get("projectMarkers") or []:
        if (project_dir / str(marker)).exists():
            return True
    return False


def detect_project_engine(project_dir: Path) -> str:
    for engine in known_engines():
        if is_engine_project(project_dir, engine):
            return engine
    return ""


def resolve_project_engine(project_dir: Path, configured: Any = None) -> str:
    requested = normalize_engine_id(configured)
    if requested in ENGINE_DEFINITIONS:
        return requested
    return detect_project_engine(project_dir)


def _relative_token(path_or_relative: str | Path, project_dir: Path) -> str:
    path = Path(path_or_relative)
    if path.is_absolute():
        try:
            return path.resolve().relative_to(project_dir.resolve()).as_posix()
        except ValueError:
            return path.name
    return path.as_posix()


def matches_patterns(relative_path: str | Path, patterns: list[str], project_dir: Path | None = None) -> bool:
    token = _relative_token(relative_path, project_dir or Path.cwd()).lstrip("./")
    return any(fnmatch.fnmatch(token, pattern) or fnmatch.fnmatch(Path(token).name, pattern) for pattern in patterns)


def engine_patterns(engine: str, key: str) -> list[str]:
    metadata = engine_metadata(engine)
    return [str(item) for item in metadata.get(key) or []]


def source_patterns(engine: str) -> list[str]:
    return engine_patterns(engine, "sourcePatterns")


def verification_patterns(engine: str) -> list[str]:
    return engine_patterns(engine, "verificationPatterns")


def display_name(engine: str) -> str:
    return str(engine_metadata(engine).get("displayName") or "")


def runtime_cache_dir(engine: str) -> str:
    return str(engine_metadata(engine).get("runtimeCacheDir") or "")


def runtime_cache_support_dir(engine: str) -> str:
    return str(engine_metadata(engine).get("runtimeCacheSupportDir") or "")


def bridge_script(engine: str) -> str:
    return str(engine_metadata(engine).get("bridgeScript") or "")


def bridge_backend(engine: str) -> str:
    return str(engine_metadata(engine).get("bridgeBackend") or "")


def bridge_server_name(engine: str) -> str:
    return str(engine_metadata(engine).get("bridgeServerName") or "")


def bridge_host_state_file(engine: str) -> str:
    return str(engine_metadata(engine).get("bridgeHostStateFile") or "")


def codex_server_prefix(engine: str) -> str:
    return str(engine_metadata(engine).get("codexServerPrefix") or "qq-")


def default_slug(engine: str) -> str:
    return str(engine_metadata(engine).get("defaultSlug") or "project")


def default_enabled_rules(engine: str) -> list[str]:
    return [str(item) for item in engine_metadata(engine).get("defaultEnabledRules") or []]


def default_test_scope(engine: str, policy_profile: str) -> str:
    metadata = engine_metadata(engine)
    policy_key = str(policy_profile or "").strip().lower() or "feature"
    scopes = metadata.get("defaultTestScopes") or {}
    value = scopes.get(policy_key) or scopes.get("feature") or "all"
    return str(value)


def host_validation_reason(engine: str) -> str:
    return str(engine_metadata(engine).get("hostValidationReason") or "")


def recommended_compile_action(engine: str) -> str:
    return str(engine_metadata(engine).get("recommendedCompileAction") or "")


def emit(payload: Any, pretty: bool) -> int:
    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if pretty else None, sort_keys=pretty)
    sys.stdout.write("\n")
    return 0


def emit_field(value: Any) -> int:
    if isinstance(value, bool):
        sys.stdout.write("true\n" if value else "false\n")
    elif isinstance(value, (dict, list)):
        sys.stdout.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")
    else:
        sys.stdout.write(f"{value}\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Resolve quick-question engine metadata")
    subparsers = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", default=".", help="Project root (defaults to cwd)")
    common.add_argument("--engine", default="", help="Explicit engine id override")
    common.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    detect = subparsers.add_parser("detect", parents=[common], help="Detect the active engine for a project")
    detect.add_argument("--required", action="store_true", help="Exit non-zero when no engine is detected")

    describe = subparsers.add_parser("describe", parents=[common], help="Describe the resolved engine metadata")

    field = subparsers.add_parser("field", parents=[common], help="Print one resolved engine field")
    field.add_argument("field", help="Metadata field name")

    match_source = subparsers.add_parser("matches-source", parents=[common], help="Return whether a path matches engine source patterns")
    match_source.add_argument("path", help="Relative or absolute path to test")

    match_verify = subparsers.add_parser("matches-verification", parents=[common], help="Return whether a path matches engine verification patterns")
    match_verify.add_argument("path", help="Relative or absolute path to test")

    return parser


def main() -> int:
    args = build_parser().parse_args()
    project_dir = Path(args.project).resolve()
    engine = resolve_project_engine(project_dir, getattr(args, "engine", ""))

    if args.command == "detect":
        if args.required and not engine:
            emit({"ok": False, "engine": "", "knownEngines": known_engines()}, args.pretty)
            return 1
        return emit({"ok": True, "engine": engine, "knownEngines": known_engines()}, args.pretty)

    if not engine:
        emit({"ok": False, "error": "No supported engine detected", "knownEngines": known_engines()}, args.pretty)
        return 1

    if args.command == "describe":
        return emit(
            {
                "ok": True,
                "engine": engine,
                "metadata": engine_metadata(engine),
            },
            args.pretty,
        )

    if args.command == "field":
        return emit_field(engine_metadata(engine).get(args.field, ""))

    if args.command == "matches-source":
        return emit_field(matches_patterns(args.path, source_patterns(engine), project_dir))

    return emit_field(matches_patterns(args.path, verification_patterns(engine), project_dir))


if __name__ == "__main__":
    raise SystemExit(main())
