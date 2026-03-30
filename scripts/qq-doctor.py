#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_REGISTRY_PATH = SCRIPT_DIR / "qq-capabilities.json"


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_optional_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        return load_json(path)
    except (OSError, json.JSONDecodeError):
        return {}


def is_unity_project(project_dir: Path) -> bool:
    return (project_dir / "ProjectSettings" / "ProjectVersion.txt").is_file()


def find_tykit_info(project_dir: Path) -> Path | None:
    for candidate in (project_dir / "Temp" / "tykit.json", project_dir / "Temp" / "eval_server.json"):
        if candidate.is_file():
            return candidate
    return None


def has_tykit_package(project_dir: Path) -> bool:
    manifest = project_dir / "Packages" / "manifest.json"
    if manifest.is_file():
        try:
            data = load_json(manifest)
        except json.JSONDecodeError:
            return False
        deps = data.get("dependencies") or {}
        if "com.tyk.tykit" in deps:
            return True
    embedded = project_dir / "Packages" / "com.tyk.tykit"
    if embedded.is_dir():
        return True
    return any("com.tyk.tykit" in path.as_posix() for path in (project_dir / "Library" / "PackageCache").glob("**/*")) if (project_dir / "Library" / "PackageCache").is_dir() else False


def find_unity_eval(project_dir: Path) -> Path | None:
    embedded = project_dir / "Packages" / "com.tyk.tykit" / "Scripts~" / "unity-eval.sh"
    if embedded.is_file():
        return embedded
    package_cache = project_dir / "Library" / "PackageCache"
    if package_cache.is_dir():
        for candidate in sorted(package_cache.glob("**/unity-eval.sh")):
            if "com.tyk.tykit" in candidate.as_posix():
                return candidate
    return None


def gather_host_config_text(project_dir: Path) -> str:
    texts: list[str] = []
    for relative in (".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"):
        path = project_dir / relative
        if path.is_file():
            try:
                texts.append(path.read_text(encoding="utf-8", errors="ignore"))
            except OSError:
                continue
    return "\n".join(texts)


def build_controller_state(project_dir: Path) -> dict[str, Any]:
    project_state_script = SCRIPT_DIR / "qq-project-state.py"
    if not project_state_script.is_file():
        return {}

    result = subprocess.run(
        ["python3", str(project_state_script), "--project", str(project_dir), "--no-write"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return {
            "error": result.stderr.strip() or result.stdout.strip() or "qq-project-state.py failed",
        }
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "error": "qq-project-state.py returned invalid JSON",
        }
    if not isinstance(payload, dict):
        return {
            "error": "qq-project-state.py returned a non-object payload",
        }
    return {
        "workMode": payload.get("work_mode") or "",
        "workModeSource": payload.get("work_mode_source") or "",
        "modeProfile": payload.get("mode_profile") or {},
        "modeRecommendedNext": payload.get("mode_recommended_next") or "",
        "policyProfile": payload.get("policy_profile") or "",
        "policyProfileSource": payload.get("policy_profile_source") or "",
        "policyProfileExpectations": payload.get("policy_profile_expectations") or {},
        "recommendedNext": payload.get("recommended_next") or "",
        "compileStatus": payload.get("last_compile_status") or "",
        "testStatus": payload.get("last_test_status") or "",
        "reviewGateStatus": payload.get("review_gate_status") or "",
        "docDriftStatus": payload.get("doc_drift_status") or "",
        "hasDesignDoc": bool(payload.get("has_design_doc")),
        "hasImplementationPlan": bool(payload.get("has_implementation_plan")),
        "hasUncommittedCsChanges": bool(payload.get("has_uncommitted_cs_changes")),
    }


def detect_provider(project_dir: Path, provider_id: str) -> dict[str, Any]:
    scripts_dir = project_dir / "scripts"
    host_config = gather_host_config_text(project_dir)

    if provider_id == "unity.qq-direct":
        required = [
            scripts_dir / "unity-compile-smart.sh",
            scripts_dir / "unity-test.sh",
            scripts_dir / "qq-project-state.py",
            scripts_dir / "qq-policy-check.sh",
        ]
        missing = [str(path.relative_to(project_dir)) for path in required if not path.is_file()]
        return {
            "id": provider_id,
            "status": "available" if not missing else "unavailable",
            "reasons": ["project-local qq fast path scripts installed"] if not missing else ["missing required fast-path scripts"],
            "evidence": {
                "missing": missing,
            },
        }

    if provider_id == "unity.tykit-mcp":
        required = [
            scripts_dir / "tykit_mcp.py",
            scripts_dir / "tykit_bridge.py",
            scripts_dir / "qq-capabilities.json",
            scripts_dir / "tykit_capabilities.json",
        ]
        missing = [str(path.relative_to(project_dir)) for path in required if not path.is_file()]
        return {
            "id": provider_id,
            "status": "available" if not missing else "unavailable",
            "reasons": ["built-in tykit MCP bridge installed"] if not missing else ["missing bridge scripts or registries"],
            "evidence": {
                "missing": missing,
            },
        }

    if provider_id == "unity.raw-tykit":
        info_file = find_tykit_info(project_dir)
        eval_script = find_unity_eval(project_dir)
        package_installed = has_tykit_package(project_dir)
        available = bool(info_file or eval_script or package_installed)
        reasons: list[str] = []
        if info_file:
            reasons.append("tykit metadata file found")
        if eval_script:
            reasons.append("unity-eval.sh available")
        if package_installed:
            reasons.append("com.tyk.tykit installed")
        if not reasons:
            reasons.append("tykit package or metadata not detected")
        return {
            "id": provider_id,
            "status": "available" if available else "unavailable",
            "reasons": reasons,
            "evidence": {
                "infoFile": str(info_file) if info_file else "",
                "evalScript": str(eval_script) if eval_script else "",
                "packageInstalled": package_installed,
            },
        }

    if provider_id == "unity.mcp-unity":
        detected = "mcp-unity" in host_config or "recompile_scripts" in host_config or "run_tests" in host_config
        return {
            "id": provider_id,
            "status": "available" if detected else "unknown",
            "reasons": ["host MCP config references mcp-unity"] if detected else ["host MCP config not detected in project-local files"],
            "evidence": {
                "configScanned": [".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"],
            },
        }

    if provider_id == "unity.unity-mcp":
        detected = "unity-mcp" in host_config.lower() or "Unity-MCP" in host_config or "tests-run" in host_config
        return {
            "id": provider_id,
            "status": "available" if detected else "unknown",
            "reasons": ["host MCP config references Unity-MCP"] if detected else ["host MCP config not detected in project-local files"],
            "evidence": {
                "configScanned": [".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"],
            },
        }

    return {
        "id": provider_id,
        "status": "unknown",
        "reasons": ["no detector implemented"],
        "evidence": {},
    }


def resolve_capabilities(registry: dict[str, Any], engine: str, provider_status: dict[str, dict[str, Any]]) -> dict[str, Any]:
    preferred = ((registry.get("resolution") or {}).get("preferredProviders") or {}).get(engine) or {}
    resolved: dict[str, Any] = {}
    for capability, ordered in preferred.items():
        available = [provider_id for provider_id in ordered if provider_status.get(provider_id, {}).get("status") == "available"]
        resolved[capability] = {
            "preferredProviders": ordered,
            "availableProviders": available,
            "resolved": available[0] if available else "",
        }
    return resolved


def write_state(project_dir: Path, payload: dict[str, Any]) -> Path:
    state_dir = project_dir / ".qq" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    output = state_dir / "provider-resolution.json"
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output


def build_payload(project_dir: Path, engine: str, registry: dict[str, Any]) -> dict[str, Any]:
    controller = build_controller_state(project_dir)
    shared_policy_path = project_dir / "qq-policy.json"
    local_policy_path = project_dir / ".qq" / "local-policy.json"
    provider_items = []
    provider_status: dict[str, dict[str, Any]] = {}
    for provider_id, definition in sorted((registry.get("providers") or {}).items()):
        if definition.get("engineAdapter") != engine:
            continue
        detection = detect_provider(project_dir, provider_id)
        entry = {
            "id": provider_id,
            "engineAdapter": definition.get("engineAdapter"),
            "transportAdapter": definition.get("transportAdapter"),
            "hostAdapters": definition.get("hostAdapters") or [],
            "official": bool(definition.get("official")),
            "capabilities": definition.get("capabilities") or [],
            **detection,
        }
        provider_items.append(entry)
        provider_status[provider_id] = entry

    return {
        "projectDir": str(project_dir),
        "engine": engine,
        "unityProjectDetected": is_unity_project(project_dir) if engine == "unity" else None,
        "policy": {
            "sharedPath": str(shared_policy_path),
            "sharedExists": shared_policy_path.is_file(),
            "shared": load_optional_json(shared_policy_path),
            "localPath": str(local_policy_path),
            "localExists": local_policy_path.is_file(),
            "local": load_optional_json(local_policy_path),
            "effectiveProfile": controller.get("policyProfile") or "",
            "effectiveProfileSource": controller.get("policyProfileSource") or "",
            "effectiveProfileExpectations": controller.get("policyProfileExpectations") or {},
        },
        "controller": controller,
        "providers": provider_items,
        "resolution": resolve_capabilities(registry, engine, provider_status),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="qq provider discovery and capability resolution doctor")
    parser.add_argument("--project", default=".", help="Project root to inspect")
    parser.add_argument("--engine", default=None, help="Engine adapter id to inspect")
    parser.add_argument("--registry", default=str(DEFAULT_REGISTRY_PATH), help="Path to qq capability registry JSON")
    parser.add_argument("--write-state", action="store_true", help="Write provider-resolution.json into .qq/state/")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    project_dir = Path(args.project).resolve()
    registry = load_json(Path(args.registry).resolve())
    engine = args.engine or registry.get("defaultEngine") or "unity"

    payload = build_payload(project_dir, engine, registry)
    if args.write_state:
        payload["statePath"] = str(write_state(project_dir, payload))

    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
