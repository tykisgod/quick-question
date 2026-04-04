#!/usr/bin/env python3
from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path
from typing import Any

from qq_internal_config import dedupe, normalize_name_list, resolve_project_config


DEFAULT_INSTALL_HOSTS = ["claude", "codex", "mcp"]
VALID_INSTALL_HOSTS = set(DEFAULT_INSTALL_HOSTS)


MODULES: dict[str, dict[str, Any]] = {
    "runtime-core": {
        "description": "Core project-local qq runtime scripts and config helpers.",
        "entries": [
            "scripts/qq-capabilities.json",
            "scripts/qq-capability.py",
            "scripts/qq-compile.sh",
            "scripts/qq-config.py",
            "scripts/qq-doctor.py",
            "scripts/qq-execute-checkpoint.py",
            "scripts/qq-doctor.sh",
            "scripts/qq-policy-check.sh",
            "scripts/qq-preflight.py",
            "scripts/qq-project-state.py",
            "scripts/qq-run-record.py",
            "scripts/qq-runtime.sh",
            "scripts/qq-test.sh",
            "scripts/qq-worktree.py",
            "scripts/qq_bridge_common.py",
            "scripts/qq_engine.py",
            "scripts/qq_internal_changes.py",
            "scripts/qq_internal_config.py",
            "scripts/qq_internal_git.py",
            "scripts/qq_internal_install.py",
            "scripts/platform/*.sh",
        ],
    },
    "project-config": {
        "description": "Shared project config surface (`qq.yaml`).",
        "entries": [],
    },
    "project-docs": {
        "description": "Project-local AGENTS/CLAUDE templates.",
        "entries": [],
    },
    "host-claude": {
        "description": "Claude-specific local permissions and project docs.",
        "entries": [],
        "depends_on": ["project-docs"],
    },
    "host-codex": {
        "description": "Codex project-local helpers and MCP registration wrappers.",
        "entries": [
            "scripts/qq-codex-exec.py",
            "scripts/qq-codex-mcp.py",
        ],
    },
    "host-mcp": {
        "description": "Built-in engine-generic project-local MCP entrypoint.",
        "entries": [
            "scripts/qq_mcp.py",
        ],
    },
    "hooks-core": {
        "description": "Common hook dispatch and cleanup runtime.",
        "entries": [
            "scripts/hooks/hook-dispatch.sh",
            "scripts/hooks/hook-dispatch.cmd",
            "scripts/hooks/session-cleanup.sh",
        ],
    },
    "hooks-auto-compile": {
        "description": "Auto-compile hook runtime.",
        "entries": [
            "scripts/hooks/auto-compile.sh",
        ],
        "depends_on": ["hooks-core"],
    },
    "hooks-compile-gate": {
        "description": "Compile-gate hook runtime — blocks source edits when compile is red.",
        "entries": [
            "scripts/hooks/compile-gate-check.sh",
        ],
        "depends_on": ["hooks-core"],
    },
    "hooks-review-gate": {
        "description": "Review-gate hook runtime.",
        "entries": [
            "scripts/hooks/review-gate-check.sh",
            "scripts/hooks/review-gate-count.sh",
            "scripts/hooks/review-gate-set.sh",
            "scripts/hooks/review-gate-stop.sh",
        ],
        "depends_on": ["hooks-core"],
    },
    "hooks-skill-review": {
        "description": "Skill-review hook runtime.",
        "entries": [
            "scripts/check-skill-review.sh",
            "scripts/hooks/skill-modified-track.sh",
        ],
        "depends_on": ["hooks-core"],
    },
    "hooks-auto-pipeline": {
        "description": "Auto-pipeline stop hook and resume hint.",
        "entries": [
            "scripts/hooks/auto-pipeline-stop.sh",
            "scripts/hooks/auto-pipeline-resume-hint.sh",
        ],
        "depends_on": ["hooks-core"],
    },
    "workflow-review-scripts": {
        "description": "Review scripts for code and plan review.",
        "entries": [
            "scripts/code-review.sh",
            "scripts/plan-review.sh",
            "scripts/claude-review.sh",
            "scripts/claude-plan-review.sh",
        ],
        "depends_on": ["runtime-core"],
    },
    "git-pre-push": {
        "description": "Git pre-push validation hook.",
        "entries": [
            {"source": "scripts/githooks/pre-push", "target": ".githooks/pre-push"},
            "scripts/hooks/pre-push-test.sh",
        ],
        "depends_on": ["runtime-core"],
    },
    "engine-unity": {
        "description": "Unity engine adapter scripts and rich bridge delegates.",
        "entries": [
            "scripts/unity-check.sh",
            "scripts/unity-common.sh",
            "scripts/unity-compile-smart.sh",
            "scripts/unity-compile.sh",
            "scripts/unity-test.sh",
            "scripts/unity-unit-test.sh",
            "scripts/tykit_bridge.py",
            "scripts/tykit_capabilities.json",
            "scripts/tykit_mcp.py",
        ],
        "depends_on": ["runtime-core"],
        "engine": "unity",
    },
    "engine-godot": {
        "description": "Godot engine adapter scripts, bridge, and editor addon assets.",
        "entries": [
            "scripts/godot-common.sh",
            "scripts/godot-compile-check.gd",
            "scripts/godot-compile.sh",
            "scripts/godot-test.sh",
            "scripts/godot_bridge.py",
            "scripts/godot_capabilities.json",
        ],
        "depends_on": ["runtime-core"],
        "engine": "godot",
    },
    "engine-unreal": {
        "description": "Unreal engine adapter scripts, bridge, and editor Python bootstrap.",
        "entries": [
            "scripts/unreal-common.sh",
            "scripts/unreal-compile-check.py",
            "scripts/unreal-compile.sh",
            "scripts/unreal-test.sh",
            "scripts/unreal_bridge.py",
            "scripts/unreal_capabilities.json",
            "scripts/unreal_editor_command.py",
        ],
        "depends_on": ["runtime-core"],
        "engine": "unreal",
    },
    "engine-sbox": {
        "description": "S&box engine adapter scripts and editor bridge runtime.",
        "entries": [
            "scripts/sbox-common.sh",
            "scripts/sbox-compile.sh",
            "scripts/sbox-test.sh",
            "scripts/sbox_bridge.py",
            "scripts/sbox_capabilities.json",
        ],
        "depends_on": ["runtime-core"],
        "engine": "sbox",
    },
}


HOOK_MODULES = {
    "auto_compile": "hooks-auto-compile",
    "compile_gate": "hooks-compile-gate",
    "review_gate": "hooks-review-gate",
    "skill_review": "hooks-skill-review",
    "auto_pipeline": "hooks-auto-pipeline",
    "git_pre_push": "git-pre-push",
}

AUTO_INSTALL_HOOK_MODULES = {
    "hooks-auto-compile",
    "hooks-compile-gate",
    "hooks-review-gate",
    "hooks-skill-review",
    "hooks-auto-pipeline",
}


ENGINE_MODULES = {
    "unity": "engine-unity",
    "godot": "engine-godot",
    "unreal": "engine-unreal",
    "sbox": "engine-sbox",
}


HOST_MODULES = {
    "claude": "host-claude",
    "codex": "host-codex",
    "mcp": "host-mcp",
}


def install_state_path(project_dir: Path) -> Path:
    return project_dir / ".qq" / "install-state.json"


def normalize_install_payload(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {
            "hosts": list(DEFAULT_INSTALL_HOSTS),
            "add_modules": [],
            "remove_modules": [],
            "sync": False,
        }
    hosts = [item for item in normalize_name_list(value.get("hosts")) if item in VALID_INSTALL_HOSTS]
    if not hosts:
        hosts = list(DEFAULT_INSTALL_HOSTS)
    sync_value = value.get("sync")
    sync = bool(sync_value) if isinstance(sync_value, bool) else False
    return {
        "hosts": dedupe(hosts),
        "add_modules": normalize_name_list(value.get("add_modules")),
        "remove_modules": normalize_name_list(value.get("remove_modules")),
        "sync": sync,
    }


def merge_install_payload(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = {
        "hosts": list(base.get("hosts") or DEFAULT_INSTALL_HOSTS),
        "add_modules": list(base.get("add_modules") or []),
        "remove_modules": list(base.get("remove_modules") or []),
        "sync": bool(base.get("sync")),
    }
    if override.get("hosts"):
        merged["hosts"] = list(override["hosts"])
    merged["add_modules"] = merge_unique(merged["add_modules"], list(override.get("add_modules") or []))
    merged["remove_modules"] = merge_unique(merged["remove_modules"], list(override.get("remove_modules") or []))
    if "sync" in override:
        merged["sync"] = bool(override["sync"])
    return merged


def merge_unique(base: list[str], additions: list[str]) -> list[str]:
    return dedupe([*base, *additions])


def _required_modules_for_engine(engine: str) -> list[str]:
    required = ["runtime-core", "project-config"]
    engine_module = ENGINE_MODULES.get(engine)
    if engine_module:
        required.append(engine_module)
    return required


def _host_modules(hosts: list[str]) -> list[str]:
    return [HOST_MODULES[host] for host in hosts if host in HOST_MODULES]


def _hook_modules(enabled_hooks: list[str]) -> list[str]:
    modules = [HOOK_MODULES[hook] for hook in enabled_hooks if hook in HOOK_MODULES]
    return [module for module in modules if module in AUTO_INSTALL_HOOK_MODULES]


def _expand_dependencies(modules: list[str]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()

    def visit(name: str) -> None:
        if name in seen or name not in MODULES:
            return
        seen.add(name)
        for dep in MODULES[name].get("depends_on") or []:
            visit(str(dep))
        ordered.append(name)

    for module in modules:
        visit(module)
    return ordered


def _resolve_entries(repo_root: Path, selected_modules: list[str]) -> list[dict[str, str]]:
    resolved: list[dict[str, str]] = []
    seen_targets: set[str] = set()
    for module in selected_modules:
        for entry in MODULES.get(module, {}).get("entries") or []:
            if isinstance(entry, str):
                matches = sorted(
                    Path(path).resolve()
                    for path in glob.glob(str(repo_root / entry), recursive=True)
                    if Path(path).is_file()
                )
                for match in matches:
                    try:
                        source_rel = match.relative_to(repo_root).as_posix()
                    except ValueError:
                        continue
                    target_rel = source_rel
                    if target_rel in seen_targets:
                        continue
                    seen_targets.add(target_rel)
                    resolved.append({"module": module, "source": source_rel, "target": target_rel})
                continue
            if isinstance(entry, dict):
                source = str(entry.get("source") or "").strip()
                target = str(entry.get("target") or "").strip()
                if not source or not target:
                    continue
                source_path = (repo_root / source).resolve()
                if not source_path.is_file() or target in seen_targets:
                    continue
                seen_targets.add(target)
                resolved.append({"module": module, "source": source, "target": target})
    return resolved


def resolve_install_plan(
    repo_root: Path,
    project_dir: Path,
    *,
    explicit_modules: list[str] | None = None,
    without_modules: list[str] | None = None,
    with_pre_push: bool = False,
    sync_override: bool | None = None,
) -> dict[str, Any]:
    config = resolve_project_config(project_dir)
    engine = str(config.get("engine") or "")
    install_preferences = normalize_install_payload(config.get("install_preferences"))

    default_modules = (
        _required_modules_for_engine(engine)
        + ["project-docs"]
        + _host_modules(list(install_preferences.get("hosts") or DEFAULT_INSTALL_HOSTS))
        + _hook_modules(list(config.get("enabled_hooks") or []))
    )
    if with_pre_push:
        default_modules.append("git-pre-push")
    default_modules = dedupe([module for module in default_modules if module in MODULES])
    default_modules = dedupe(default_modules + [m for m in install_preferences.get("add_modules") or [] if m in MODULES])
    default_modules = [m for m in default_modules if m not in set(install_preferences.get("remove_modules") or [])]

    requested_modules = [module for module in (explicit_modules or default_modules) if module in MODULES]
    requested_modules = dedupe(requested_modules + _required_modules_for_engine(engine))
    requested_modules = [m for m in requested_modules if m not in set(without_modules or []) or m in _required_modules_for_engine(engine)]
    selected_modules = _expand_dependencies(requested_modules)
    entries = _resolve_entries(repo_root, selected_modules)

    sync_enabled = bool(sync_override) if sync_override is not None else bool(install_preferences.get("sync"))

    return {
        "engine": engine,
        "profile": str(config.get("profile") or ""),
        "defaultModules": default_modules,
        "selectedModules": selected_modules,
        "requiredModules": _required_modules_for_engine(engine),
        "hosts": list(install_preferences.get("hosts") or DEFAULT_INSTALL_HOSTS),
        "sync": sync_enabled,
        "moduleDetails": {name: MODULES[name] for name in selected_modules},
        "entries": entries,
        "managedTargets": [entry["target"] for entry in entries],
    }


def load_install_state(project_dir: Path) -> dict[str, Any]:
    path = install_state_path(project_dir)
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve qq install modules")
    subparsers = parser.add_subparsers(dest="command", required=False)

    resolve_parser = subparsers.add_parser("resolve", help="Resolve the effective install plan")
    resolve_parser.add_argument("--project", default=".", help="Project root")
    resolve_parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[1]), help="quick-question repo root")
    resolve_parser.add_argument("--modules", default="", help="Comma-separated explicit module set")
    resolve_parser.add_argument("--without", default="", help="Comma-separated modules to drop from the plan")
    resolve_parser.add_argument("--with-pre-push", action="store_true", help="Force-install the git pre-push module")
    resolve_parser.add_argument("--sync", action="store_true", help="Force sync mode on")
    resolve_parser.add_argument("--pretty", action="store_true", help="Pretty-print output")

    state_parser = subparsers.add_parser("state", help="Read install-state.json")
    state_parser.add_argument("--project", default=".", help="Project root")
    state_parser.add_argument("--pretty", action="store_true", help="Pretty-print output")

    args = parser.parse_args()
    command = args.command or "resolve"

    if command == "state":
        payload = load_install_state(Path(args.project).resolve())
        print(json.dumps(payload, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty))
        return 0

    plan = resolve_install_plan(
        Path(args.repo_root).resolve(),
        Path(args.project).resolve(),
        explicit_modules=normalize_name_list(args.modules),
        without_modules=normalize_name_list(args.without),
        with_pre_push=bool(args.with_pre_push),
        sync_override=True if args.sync else None,
    )
    print(json.dumps(plan, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
