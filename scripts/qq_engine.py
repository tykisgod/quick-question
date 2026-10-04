#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import itertools
import json
import os
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Iterator


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
        "editorBridgeLogFile": ".qq/state/qq-godot-editor.log",
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
    "unreal": {
        "displayName": "Unreal",
        "projectMarkers": ["*.uproject"],
        "sourcePatterns": [
            "Source/*.cpp",
            "Source/*.h",
            "Source/*.cs",
            "Source/*.Build.cs",
            "Source/*.Target.cs",
            "Source/**/*.cpp",
            "Source/**/*.h",
            "Source/**/*.cs",
            "Source/**/*.Build.cs",
            "Source/**/*.Target.cs",
            "Plugins/*.cpp",
            "Plugins/*.h",
            "Plugins/*.cs",
            "Plugins/*.Build.cs",
            "Plugins/*.Target.cs",
            "Plugins/**/*.cpp",
            "Plugins/**/*.h",
            "Plugins/**/*.cs",
            "Plugins/**/*.Build.cs",
            "Plugins/**/*.Target.cs",
        ],
        "verificationPatterns": [
            "*.uproject",
            "Config/*.ini",
            "Config/**/*.ini",
            "Source/*.cpp",
            "Source/*.h",
            "Source/*.cs",
            "Source/*.Build.cs",
            "Source/*.Target.cs",
            "Source/**/*.cpp",
            "Source/**/*.h",
            "Source/**/*.cs",
            "Source/**/*.Build.cs",
            "Source/**/*.Target.cs",
            "Plugins/*.uplugin",
            "Plugins/*.cpp",
            "Plugins/*.h",
            "Plugins/*.cs",
            "Plugins/*.Build.cs",
            "Plugins/*.Target.cs",
            "Plugins/**/*.uplugin",
            "Plugins/**/*.cpp",
            "Plugins/**/*.h",
            "Plugins/**/*.cs",
            "Plugins/**/*.Build.cs",
            "Plugins/**/*.Target.cs",
            "Content/*.uasset",
            "Content/*.umap",
            "Content/**/*.uasset",
            "Content/**/*.umap",
        ],
        "runtimeCacheDir": "Intermediate",
        "runtimeCacheSupportDir": "Binaries",
        "bridgeScript": "qq_mcp.py",
        "bridgeBackend": "qq-unreal-python",
        "bridgeServerName": "qq-unreal",
        "bridgeHostStateFile": "qq-unreal-mcp-host.json",
        "editorBridgeStateFile": ".qq/state/qq-unreal-editor-bridge.json",
        "editorBridgeRequestDir": ".qq/state/qq-unreal-editor/requests",
        "editorBridgeResponseDir": ".qq/state/qq-unreal-editor/responses",
        "editorBridgeConsoleFile": ".qq/state/qq-unreal-editor-console.jsonl",
        "editorBridgeLogFile": ".qq/state/qq-unreal-editor.log",
        "editorBridgeStartupCommand": "import qq_unreal_bridge; qq_unreal_bridge.start()",
        "engineSupportSourceDir": "engines/unreal/python",
        "engineSupportTargetDir": "Content/Python",
        "codexServerPrefix": "qq-unreal-",
        "defaultSlug": "unreal-project",
        "requiredProjectPlugins": [
            "PythonScriptPlugin",
            "EditorScriptingUtilities",
        ],
        "defaultEnabledRules": [
            "get_all_actors_in_hot_path",
            "component_lookup_in_tick",
        ],
        "defaultTestScopes": {
            "core": "all",
            "feature": "all",
            "hardening": "all",
        },
        "hostValidationReason": "Unreal project validation is engine-local and should run against the project on the host machine.",
        "recommendedCompileAction": "./scripts/qq-compile.sh",
    },
    "sbox": {
        "displayName": "S&box",
        "projectMarkers": [".sbproj", "*.sbproj"],
        "sourcePatterns": [
            "Code/*.cs",
            "Code/**/*.cs",
            "Code/*.razor",
            "Code/**/*.razor",
            "Editor/*.cs",
            "Editor/**/*.cs",
            "Editor/*.razor",
            "Editor/**/*.razor",
            "Libraries/*/Code/*.cs",
            "Libraries/*/Code/**/*.cs",
            "Libraries/*/Code/*.razor",
            "Libraries/*/Code/**/*.razor",
            "Libraries/*/Editor/*.cs",
            "Libraries/*/Editor/**/*.cs",
            "Libraries/*/Editor/*.razor",
            "Libraries/*/Editor/**/*.razor",
            "UnitTests/*.cs",
            "UnitTests/**/*.cs",
        ],
        "verificationPatterns": [
            ".sbproj",
            "*.sbproj",
            "*.sln",
            "*.csproj",
            "Code/*.cs",
            "Code/**/*.cs",
            "Code/*.razor",
            "Code/**/*.razor",
            "Editor/*.cs",
            "Editor/**/*.cs",
            "Editor/*.razor",
            "Editor/**/*.razor",
            "Libraries/*.csproj",
            "Libraries/**/*.csproj",
            "Libraries/*/Code/*.cs",
            "Libraries/*/Code/**/*.cs",
            "Libraries/*/Code/*.razor",
            "Libraries/*/Code/**/*.razor",
            "Libraries/*/Editor/*.cs",
            "Libraries/*/Editor/**/*.cs",
            "Libraries/*/Editor/*.razor",
            "Libraries/*/Editor/**/*.razor",
            "Assets/*",
            "Assets/**/*",
            "UnitTests/*.cs",
            "UnitTests/**/*.cs",
            "UnitTests/*.csproj",
            "UnitTests/**/*.csproj",
        ],
        "runtimeCacheDir": "",
        "runtimeCacheSupportDir": "",
        "bridgeScript": "qq_mcp.py",
        "bridgeBackend": "qq-sbox-editor",
        "bridgeServerName": "qq-sbox",
        "bridgeHostStateFile": "qq-sbox-mcp-host.json",
        "editorBridgeStateFile": ".qq/state/qq-sbox-editor-bridge.json",
        "editorBridgeRequestDir": ".qq/state/qq-sbox-editor/requests",
        "editorBridgeResponseDir": ".qq/state/qq-sbox-editor/responses",
        "editorBridgeConsoleFile": ".qq/state/qq-sbox-editor-console.jsonl",
        "engineSupportSourceDir": "engines/sbox/Editor/QQ",
        "engineSupportTargetDir": "Editor/QQ",
        "codexServerPrefix": "qq-sbox-",
        "defaultSlug": "sbox-project",
        "defaultEnabledRules": [
            "sbox_whitelist_violation",
            "sbox_library_boundary",
        ],
        "defaultTestScopes": {
            "core": "unit",
            "feature": "unit",
            "hardening": "unit",
        },
        "hostValidationReason": "S&box validation should run against the local project targets on the host machine.",
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
        token = str(marker)
        if any(char in token for char in "*?[]"):
            if any(path.exists() for path in project_dir.glob(token)):
                return True
            continue
        if (project_dir / token).exists():
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


def _lexical_absolute(path: Path) -> Path:
    # 只做词法规范化（补成绝对路径、折叠 . 和 ..），不碰文件系统，保留路径上的符号链接原样
    return Path(os.path.abspath(path))


def _resolved_absolute(path: Path) -> Path:
    # 解开符号链接、目录联接和 Windows 8.3 短名；文件还不存在时 resolve 只解析已存在的前缀
    try:
        return path.resolve()
    except (OSError, RuntimeError, ValueError):
        return _lexical_absolute(path)


def _same_directory(left: Path, right: Path) -> bool:
    try:
        return os.path.samefile(left, right)
    except (OSError, ValueError):
        return False


def _parts_under(path: Path, root: Path, ask_filesystem: bool = False) -> tuple[str, ...] | None:
    # 按路径段比较。os.path.normcase 在 Windows 上不分大小写（盘符 E: 与 e: 算同一个），POSIX 上原样比较。
    # ask_filesystem 时字符串对不上再问文件系统：path 在项目根那一级的前缀是不是同一个目录——
    # macOS 默认卷不分大小写，可 normcase 和 resolve 在那里都不动大小写，MyGame 与 mygame 只能这样对上。
    # 项目根本身不算项目里的文件
    root_parts = root.parts
    path_parts = path.parts
    if len(path_parts) <= len(root_parts):
        return None
    head = path_parts[: len(root_parts)]
    if [os.path.normcase(part) for part in head] != [os.path.normcase(part) for part in root_parts]:
        if not (ask_filesystem and _same_directory(Path(*head), root)):
            return None
    return path_parts[len(root_parts):]


def _is_linked_worktree(directory: Path) -> bool:
    # git worktree add 建的检出：.git 是一个文件，指向的管理目录（<仓库>/.git/worktrees/<名>）里有 commondir。
    # 子模块的 .git 也是文件，但指向 .git/modules/<名>，那里没有 commondir，照旧算项目里
    try:
        lines = (directory / ".git").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return False
    if not lines or not lines[0].startswith("gitdir:"):
        return False
    gitdir = Path(lines[0][len("gitdir:"):].strip())
    if not gitdir.is_absolute():
        gitdir = directory / gitdir
    try:
        return (gitdir / "commondir").is_file()
    except OSError:
        return False


def _parts_within(spellings: tuple[Path, ...], root_dir: Path) -> tuple[str, ...] | None:
    # 文件路径和根目录各取「词法规范化」与「resolve」两种绝对写法交叉比较，任一组落在根下就算根里：
    # 一边是 8.3 短名或经由符号链接给出时靠 resolve 对上；项目里某个子目录是指向项目外的链接时靠词法写法对上。
    # 四组字符串都对不上，才逐组问文件系统（见 _parts_under）
    roots = (_lexical_absolute(root_dir), _resolved_absolute(root_dir))
    for ask_filesystem in (False, True):
        for path in spellings:
            for root in roots:
                parts = _parts_under(path, root, ask_filesystem)
                if not parts:
                    continue
                # 根和文件之间某一级是 git worktree（<主目录>/.claude/worktrees/<名> 这种建在项目根下面的检出）：
                # 那是另一份检出，引擎不会把它编进这个项目
                directory = Path(*path.parts[: len(root.parts)])
                for part in parts[:-1]:
                    directory = directory / part
                    if _is_linked_worktree(directory):
                        return None
                return parts
    return None


def _relative_token(
    path_or_relative: str | Path, project_dir: Path, extra_roots: Iterable[Path] = ()
) -> str | None:
    # 换算成相对项目根的 POSIX 写法；不在项目根下就返回 None。
    # 相对路径按项目根解释；规范化后带 .. 跳出项目根的算外面。
    # 不在项目根下时再看 extra_roots（引擎明确编进项目、却放在项目根外面的目录），落在其中之一就换算成相对它的写法
    raw = Path(path_or_relative)
    candidate = raw if raw.is_absolute() else _lexical_absolute(project_dir) / raw
    spellings = (_lexical_absolute(candidate), _resolved_absolute(candidate))
    for root in itertools.chain((project_dir,), extra_roots):
        parts = _parts_within(spellings, root)
        if parts:
            return "/".join(parts)
    return None


def unity_local_package_roots(project_dir: Path) -> Iterator[Path]:
    # Packages/manifest.json 里用 "file:<目录>" 引用的本地包：可以放在项目根外面，Unity 照样把它编进项目。
    # 相对路径按 Packages/ 目录解释；指向 .tgz 这类文件的不算。写成生成器，项目里的文件用不着读 manifest
    packages_dir = project_dir / "Packages"
    try:
        manifest = json.loads((packages_dir / "manifest.json").read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return
    dependencies = manifest.get("dependencies") if isinstance(manifest, dict) else None
    if not isinstance(dependencies, dict):
        return
    for value in dependencies.values():
        if not isinstance(value, str) or not value.startswith("file:"):
            continue
        target = Path(value[len("file:"):])
        if not target.is_absolute():
            target = packages_dir / target
        if target.is_dir():
            yield target


def matches_patterns(
    relative_path: str | Path, patterns: list[str], project_dir: Path | None = None, extra_roots: Iterable[Path] = ()
) -> bool:
    # 项目外的路径一律不算：草稿目录里写个 .cs 不该触发编译或编译门。例外只有 extra_roots（Unity 的本地包）
    token = _relative_token(relative_path, project_dir or Path.cwd(), extra_roots)
    if token is None:
        return False
    # 按文件名匹配的分支保留：只写了文件名的模式（Godot 的 project.godot、S&box 的 .sbproj）靠它在子目录里也能命中
    name = PurePosixPath(token).name
    return any(fnmatch.fnmatch(token, pattern) or fnmatch.fnmatch(name, pattern) for pattern in patterns)


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

    # 判断「在不在项目里」用未 resolve 的原始项目路径，词法写法和 resolve 写法都由 matches_patterns 自己比
    match_root = Path(args.project)
    extra_roots = unity_local_package_roots(match_root) if engine == "unity" else ()
    if args.command == "matches-source":
        return emit_field(matches_patterns(args.path, source_patterns(engine), match_root, extra_roots))

    return emit_field(matches_patterns(args.path, verification_patterns(engine), match_root, extra_roots))


if __name__ == "__main__":
    raise SystemExit(main())
