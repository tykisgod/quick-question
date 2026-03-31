#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from qq_engine import (
    default_enabled_rules as engine_default_enabled_rules,
    default_test_scope as engine_default_test_scope,
    known_engines,
    normalize_engine_id,
    resolve_project_engine,
)


WORK_MODE_ALIASES = {
    "release": "hardening",
}


WORK_MODE_PROFILES: dict[str, dict[str, Any]] = {
    "prototype": {
        "description": "Fast playable spike. Keep compile green, validate the idea quickly, and record keep/drop/observe.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": False,
        "test_expectation": "targeted_or_manual",
        "changes_summary_expected": True,
    },
    "feature": {
        "description": "Build a retainable feature. Prefer a concise design, a plan, compile verification, and targeted testing.",
        "design_doc_expected": True,
        "implementation_plan_expected": True,
        "review_expected": True,
        "test_expectation": "targeted",
        "changes_summary_expected": False,
    },
    "fix": {
        "description": "Bug-fix mode. Reproduce first, make the smallest safe change, and run the regression path before moving on.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": False,
        "test_expectation": "regression",
        "changes_summary_expected": False,
    },
    "hardening": {
        "description": "Stability-sensitive work. Use it for risky refactors, release prep, or anything that needs tests and review before push.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": True,
        "test_expectation": "full_or_targeted",
        "changes_summary_expected": False,
    },
}


POLICY_PROFILES: dict[str, dict[str, Any]] = {
    "core": {
        "description": "Lowest-friction runtime baseline. Compile is required; tests and review stay advisory.",
        "compile_required": True,
        "test_expectation": "basic",
        "policy_check_expectation": "advisory",
        "review_expectation": "off",
        "doc_drift_expectation": "off",
        "default_test_scope": "editmode",
    },
    "feature": {
        "description": "Balanced daily-development defaults. Compile is required; targeted tests and lightweight review are expected.",
        "compile_required": True,
        "test_expectation": "targeted",
        "policy_check_expectation": "expected",
        "review_expectation": "light",
        "doc_drift_expectation": "advisory",
        "default_test_scope": "all",
    },
    "hardening": {
        "description": "Higher-confidence defaults for risky work. Expect compile, stronger tests, review, and doc/code consistency.",
        "compile_required": True,
        "test_expectation": "strong",
        "policy_check_expectation": "required",
        "review_expectation": "required",
        "doc_drift_expectation": "required",
        "default_test_scope": "all",
    },
}


DEFAULT_ENABLED_RULES: list[str] = []


VALID_CONTEXT_CAPSULE_TRIGGERS = {
    "manual",
    "resume",
    "pre_clear",
    "worktree_handoff",
    "after_blocker",
}
DEFAULT_CONTEXT_CAPSULE_TRIGGERS = ["resume", "pre_clear", "worktree_handoff", "after_blocker"]
DEFAULT_CONTEXT_CAPSULE = {
    "enabled": True,
    "mode": "auto",
    "triggers": list(DEFAULT_CONTEXT_CAPSULE_TRIGGERS),
    "max_chars": 3000,
}


PACKS: dict[str, dict[str, Any]] = {
    "runtime-core": {
        "description": "Core runtime loop: state, go, test, changes.",
        "skills": ["go", "test", "changes"],
        "hooks": [],
    },
    "workflow-basic": {
        "description": "Basic execution, test authoring, and ship actions.",
        "skills": ["execute", "add-tests", "commit-push"],
        "hooks": [],
    },
    "workflow-planning": {
        "description": "Design and plan oriented workflow skills.",
        "skills": ["design", "plan"],
        "hooks": [],
    },
    "workflow-review": {
        "description": "Review-oriented workflow skills.",
        "skills": [
            "best-practice",
            "claude-code-review",
            "claude-plan-review",
            "codex-code-review",
            "codex-plan-review",
            "self-review",
        ],
        "hooks": [],
    },
    "workflow-docs": {
        "description": "Doc consistency and project summary workflow skills.",
        "skills": ["brief", "full-brief", "timeline", "doc-tidy", "doc-drift"],
        "hooks": [],
    },
    "workflow-utility": {
        "description": "Utility skills that remain useful in most profiles.",
        "skills": ["research", "explain", "grandma", "deps"],
        "hooks": [],
    },
    "hooks-auto-compile": {
        "description": "Compile engine runtime code automatically after edits.",
        "skills": [],
        "hooks": ["auto_compile"],
    },
    "hooks-review-gate": {
        "description": "Lock edits until review findings are verified.",
        "skills": [],
        "hooks": ["review_gate"],
    },
    "hooks-skill-review": {
        "description": "Require self-review when editing qq skills/config.",
        "skills": [],
        "hooks": ["skill_review"],
    },
    "git-pre-push": {
        "description": "Run git pre-push validation according to the active profile.",
        "skills": [],
        "hooks": ["git_pre_push"],
    },
}


BUILTIN_PROFILES: dict[str, dict[str, Any]] = {
    "lightweight": {
        "description": "Smallest usable qq footprint: runtime, compile/test, explicit test authoring, go, execute, and changes with almost no ceremony.",
        "work_mode": "prototype",
        "policy_profile": "core",
        "packs": [
            "runtime-core",
            "workflow-basic",
            "workflow-utility",
            "hooks-auto-compile",
        ],
    },
    "core": {
        "extends": "lightweight",
        "description": "Low-friction daily runtime. Keep verification light while staying on the retainable-feature path.",
        "work_mode": "feature",
        "policy_profile": "core",
    },
    "feature": {
        "extends": "core",
        "description": "Balanced feature-development defaults: plan, review, compile, explicit test authoring, and targeted validation.",
        "work_mode": "feature",
        "policy_profile": "feature",
        "add_packs": [
            "workflow-planning",
            "workflow-review",
            "hooks-review-gate",
            "git-pre-push",
        ],
    },
    "hardening": {
        "extends": "feature",
        "description": "Higher-confidence profile for risky refactors, stabilization, and release prep.",
        "work_mode": "hardening",
        "policy_profile": "hardening",
        "add_packs": [
            "workflow-docs",
            "hooks-skill-review",
        ],
    },
}


ALL_KNOWN_SKILLS = sorted({skill for payload in PACKS.values() for skill in payload["skills"]})
ALL_KNOWN_HOOKS = sorted({hook for payload in PACKS.values() for hook in payload["hooks"]})


def normalize_work_mode(value: Any) -> str:
    raw = str(value or "").strip().lower()
    return WORK_MODE_ALIASES.get(raw, raw)


def normalize_policy_profile(value: Any) -> str:
    return str(value or "").strip().lower()


def dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        ordered.append(item)
    return ordered


def parse_scalar(value: str) -> Any:
    value = value.strip()
    if value == "":
        return ""
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if value in {"null", "Null", "none", "None", "~"}:
        return None
    if value.startswith(("'", '"')) and value.endswith(("'", '"')) and len(value) >= 2:
        return value[1:-1]
    if value.startswith("[") or value.startswith("{"):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            pass
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        pass
    return value


def _strip_comment(line: str) -> str:
    if "#" not in line:
        return line.rstrip()
    in_single = False
    in_double = False
    result: list[str] = []
    for char in line:
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        if char == "#" and not in_single and not in_double:
            break
        result.append(char)
    return "".join(result).rstrip()


def _preprocess_yaml(text: str) -> list[tuple[int, str]]:
    lines: list[tuple[int, str]] = []
    for raw in text.splitlines():
        if not raw.strip():
            continue
        stripped = _strip_comment(raw)
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append((indent, stripped.lstrip(" ")))
    return lines


def _parse_block(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[Any, int]:
    container: Any = None
    while index < len(lines):
        line_indent, content = lines[index]
        if line_indent < indent:
            break
        if line_indent > indent:
            raise ValueError(f"Unexpected indentation near: {content}")

        if content.startswith("- "):
            if container is None:
                container = []
            if not isinstance(container, list):
                raise ValueError("Cannot mix list and mapping entries in the same block")
            item_text = content[2:].strip()
            if item_text == "":
                item, index = _parse_block(lines, index + 1, indent + 2)
                container.append(item)
                continue
            container.append(parse_scalar(item_text))
            index += 1
            continue

        if container is None:
            container = {}
        if not isinstance(container, dict):
            raise ValueError("Cannot mix mapping and list entries in the same block")

        key, sep, rest = content.partition(":")
        if sep == "":
            raise ValueError(f"Invalid mapping entry: {content}")
        key = key.strip()
        rest = rest.strip()
        if rest == "":
            if index + 1 < len(lines) and lines[index + 1][0] > indent:
                value, index = _parse_block(lines, index + 1, indent + 2)
                container[key] = value
            else:
                container[key] = {}
                index += 1
        else:
            container[key] = parse_scalar(rest)
            index += 1

    if container is None:
        container = {}
    return container, index


def load_structured_file(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        lines = _preprocess_yaml(text)
        if not lines:
            return {}
        payload, index = _parse_block(lines, 0, lines[0][0])
        if index != len(lines):
            raise ValueError(f"Could not parse the full config file: {path}")
    if not isinstance(payload, dict):
        raise ValueError(f"Config root must be a mapping: {path}")
    return payload


def read_optional_structured(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        return load_structured_file(path)
    except Exception:
        return {}


def merge_unique(base: list[str], additions: list[str]) -> list[str]:
    return dedupe([*base, *additions])


def remove_items(items: list[str], removals: list[str]) -> list[str]:
    blocked = set(removals)
    return [item for item in items if item not in blocked]


def normalize_name_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    return []


def normalized_toggle(value: Any) -> dict[str, list[str]]:
    if not isinstance(value, dict):
        return {"enable": [], "disable": []}
    return {
        "enable": normalize_name_list(value.get("enable")),
        "disable": normalize_name_list(value.get("disable")),
    }


def normalize_context_capsule_payload(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}

    enabled = value.get("enabled")
    if not isinstance(enabled, bool):
        enabled = DEFAULT_CONTEXT_CAPSULE["enabled"]

    mode = str(value.get("mode") or "").strip().lower()
    if mode not in {"off", "manual", "auto"}:
        mode = DEFAULT_CONTEXT_CAPSULE["mode"]

    triggers = normalize_name_list(value.get("triggers"))
    triggers = [trigger for trigger in triggers if trigger in VALID_CONTEXT_CAPSULE_TRIGGERS]
    if not triggers:
        triggers = list(DEFAULT_CONTEXT_CAPSULE_TRIGGERS)

    max_chars_raw = value.get("max_chars")
    try:
        max_chars = max(400, int(max_chars_raw))
    except (TypeError, ValueError):
        max_chars = int(DEFAULT_CONTEXT_CAPSULE["max_chars"])

    return {
        "enabled": enabled,
        "mode": mode,
        "triggers": dedupe(triggers),
        "max_chars": max_chars,
    }


def merge_context_capsule_payload(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(DEFAULT_CONTEXT_CAPSULE)
    merged.update(base)
    if not override:
        return merged
    merged.update(override)
    merged["triggers"] = dedupe(
        [
            trigger
            for trigger in list(merged.get("triggers") or [])
            if trigger in VALID_CONTEXT_CAPSULE_TRIGGERS
        ]
        or list(DEFAULT_CONTEXT_CAPSULE_TRIGGERS)
    )
    if merged.get("mode") == "off":
        merged["enabled"] = False
    elif not merged.get("enabled"):
        merged["mode"] = "off"
    return merged


def normalize_profile_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "description": str(payload.get("description") or ""),
        "extends": str(payload.get("extends") or ""),
        "work_mode": normalize_work_mode(payload.get("work_mode") or ""),
        "policy_profile": normalize_policy_profile(payload.get("policy_profile") or ""),
        "packs": normalize_name_list(payload.get("packs")),
        "add_packs": normalize_name_list(payload.get("add_packs")),
        "remove_packs": normalize_name_list(payload.get("remove_packs")),
        "enabled_rules": normalize_name_list(payload.get("enabled_rules")),
        "add_rules": normalize_name_list(payload.get("add_rules")),
        "remove_rules": normalize_name_list(payload.get("remove_rules")),
        "skills": normalized_toggle(payload.get("skills")),
        "hooks": normalized_toggle(payload.get("hooks")),
        "context_capsule": normalize_context_capsule_payload(payload.get("context_capsule")),
    }


def merge_profile_payload(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    if override.get("description"):
        merged["description"] = override["description"]
    if override.get("work_mode"):
        merged["work_mode"] = override["work_mode"]
    if override.get("policy_profile"):
        merged["policy_profile"] = override["policy_profile"]
    if override.get("packs"):
        merged["packs"] = list(override["packs"])
    merged["packs"] = remove_items(merge_unique(list(merged.get("packs") or []), list(override.get("add_packs") or [])), list(override.get("remove_packs") or []))
    if override.get("enabled_rules"):
        merged["enabled_rules"] = list(override["enabled_rules"])
    merged["enabled_rules"] = remove_items(merge_unique(list(merged.get("enabled_rules") or []), list(override.get("add_rules") or [])), list(override.get("remove_rules") or []))
    merged["skills"] = {
        "enable": merge_unique(list((merged.get("skills") or {}).get("enable") or []), list((override.get("skills") or {}).get("enable") or [])),
        "disable": merge_unique(list((merged.get("skills") or {}).get("disable") or []), list((override.get("skills") or {}).get("disable") or [])),
    }
    merged["hooks"] = {
        "enable": merge_unique(list((merged.get("hooks") or {}).get("enable") or []), list((override.get("hooks") or {}).get("enable") or [])),
        "disable": merge_unique(list((merged.get("hooks") or {}).get("disable") or []), list((override.get("hooks") or {}).get("disable") or [])),
    }
    merged["context_capsule"] = merge_context_capsule_payload(
        dict(merged.get("context_capsule") or DEFAULT_CONTEXT_CAPSULE),
        dict(override.get("context_capsule") or {}),
    )
    return merged


def resolve_profile(name: str, custom_profiles: dict[str, dict[str, Any]], stack: set[str] | None = None) -> dict[str, Any]:
    stack = stack or set()
    profile_name = str(name or "").strip() or "feature"
    if profile_name in stack:
        raise ValueError(f"Profile inheritance cycle detected: {profile_name}")
    stack.add(profile_name)

    if profile_name in custom_profiles:
        payload = normalize_profile_payload(custom_profiles[profile_name])
    elif profile_name in BUILTIN_PROFILES:
        payload = normalize_profile_payload(BUILTIN_PROFILES[profile_name])
    else:
        payload = normalize_profile_payload(BUILTIN_PROFILES["feature"])
        profile_name = "feature"

    base_name = payload.get("extends") or ""
    if base_name:
        base = resolve_profile(base_name, custom_profiles, stack)
    else:
        base = {
            "description": "",
            "work_mode": "feature",
            "policy_profile": "feature",
            "packs": [],
            "enabled_rules": list(DEFAULT_ENABLED_RULES),
            "skills": {"enable": [], "disable": []},
            "hooks": {"enable": [], "disable": []},
            "context_capsule": dict(DEFAULT_CONTEXT_CAPSULE),
        }

    stack.remove(profile_name)
    return merge_profile_payload(base, payload)


def _default_profile_from_shared(shared: dict[str, Any]) -> str:
    raw = str(shared.get("default_profile") or "").strip()
    if raw:
        return raw
    return "feature"


def _local_profile_name(local: dict[str, Any]) -> str:
    explicit = str(local.get("profile") or "").strip()
    return explicit


def _toggle_enabled(base_items: list[str], toggle: dict[str, list[str]], universe: list[str] | None = None) -> list[str]:
    enabled = merge_unique(list(base_items), list(toggle.get("enable") or []))
    enabled = remove_items(enabled, list(toggle.get("disable") or []))
    if universe is not None:
        known = set(universe)
        enabled = [item for item in enabled if item in known]
    return dedupe(enabled)


def policy_floor_packs(policy_profile: str) -> list[str]:
    packs: list[str] = []
    if policy_profile in {"feature", "hardening"}:
        packs.extend(["workflow-review", "hooks-review-gate"])
    if policy_profile == "hardening":
        packs.append("workflow-docs")
    return [pack for pack in dedupe(packs) if pack in PACKS]


def resolve_project_config(project_dir: Path) -> dict[str, Any]:
    shared_yaml_path = project_dir / "qq.yaml"
    local_yaml_path = project_dir / ".qq" / "local.yaml"

    shared = read_optional_structured(shared_yaml_path)
    shared_source = "qq_yaml" if shared else ""
    config_format = "qq_yaml" if shared_yaml_path.is_file() else "built_in_default"

    local = read_optional_structured(local_yaml_path)
    local_source = "qq_local_yaml" if local else ""

    available_engines = known_engines()
    requested_engine = normalize_engine_id(local.get("engine") or "")
    engine_source = local_source if requested_engine in available_engines else ""
    if requested_engine not in available_engines:
        requested_engine = normalize_engine_id(shared.get("engine") or "")
        engine_source = shared_source if requested_engine in available_engines else ""
    engine = resolve_project_engine(project_dir, requested_engine)
    if engine and not engine_source:
        engine_source = "detected"

    custom_profiles = shared.get("profiles") if isinstance(shared.get("profiles"), dict) else {}
    default_profile = _default_profile_from_shared(shared)
    requested_profile = _local_profile_name(local) or default_profile
    profile_source = local_source if _local_profile_name(local) else (shared_source if shared_source != "default" else "default")

    profile_defaults = resolve_profile(requested_profile, custom_profiles)
    shared_override = normalize_profile_payload(shared)
    resolved_profile = merge_profile_payload(profile_defaults, shared_override)

    work_mode = normalize_work_mode(local.get("work_mode") or "")
    work_mode_source = local_source if work_mode in WORK_MODE_PROFILES else ""
    if work_mode not in WORK_MODE_PROFILES:
        work_mode = normalize_work_mode(resolved_profile.get("work_mode") or "")
        work_mode_source = shared_source if shared_override.get("work_mode") in WORK_MODE_PROFILES else "profile"
    if work_mode not in WORK_MODE_PROFILES:
        work_mode = "feature"
        work_mode_source = "default"
    elif config_format == "built_in_default" and work_mode_source == "profile":
        work_mode_source = "default"

    policy_profile = normalize_policy_profile(local.get("policy_profile") or "")
    policy_profile_source = local_source if policy_profile in POLICY_PROFILES else ""
    if policy_profile not in POLICY_PROFILES:
        policy_profile = normalize_policy_profile(resolved_profile.get("policy_profile") or "")
        policy_profile_source = shared_source if shared_override.get("policy_profile") in POLICY_PROFILES else "profile"
    if policy_profile not in POLICY_PROFILES:
        policy_profile = "feature"
        policy_profile_source = "default"
    elif config_format == "built_in_default" and policy_profile_source == "profile":
        policy_profile_source = "default"

    packs = list(resolved_profile.get("packs") or [])
    packs = remove_items(merge_unique(packs, normalize_name_list(local.get("add_packs"))), normalize_name_list(local.get("remove_packs")))
    packs = merge_unique(packs, policy_floor_packs(policy_profile))
    packs = [pack for pack in packs if pack in PACKS]

    shared_context_capsule = normalize_context_capsule_payload(shared.get("context_capsule"))
    local_context_capsule = normalize_context_capsule_payload(local.get("context_capsule"))
    context_capsule = merge_context_capsule_payload(
        merge_context_capsule_payload(
            dict(resolved_profile.get("context_capsule") or DEFAULT_CONTEXT_CAPSULE),
            shared_context_capsule,
        ),
        local_context_capsule,
    )

    engine_rules = engine_default_enabled_rules(engine) if engine else list(DEFAULT_ENABLED_RULES)
    profile_rules = list(resolved_profile.get("enabled_rules") or engine_rules)
    if not profile_rules:
        profile_rules = list(engine_rules)
    enabled_rules = remove_items(merge_unique(profile_rules, normalize_name_list(local.get("add_rules"))), normalize_name_list(local.get("remove_rules")))
    if local.get("enabled_rules"):
        enabled_rules = normalize_name_list(local.get("enabled_rules"))
    if not enabled_rules:
        enabled_rules = list(engine_rules)

    pack_skills = dedupe([skill for pack in packs for skill in PACKS[pack]["skills"]])
    pack_hooks = dedupe([hook for pack in packs for hook in PACKS[pack]["hooks"]])

    profile_skill_toggle = resolved_profile.get("skills") or {"enable": [], "disable": []}
    profile_hook_toggle = resolved_profile.get("hooks") or {"enable": [], "disable": []}
    local_skill_toggle = normalized_toggle(local.get("skills"))
    local_hook_toggle = normalized_toggle(local.get("hooks"))

    enabled_skills = _toggle_enabled(pack_skills, profile_skill_toggle, ALL_KNOWN_SKILLS)
    enabled_skills = _toggle_enabled(enabled_skills, local_skill_toggle, ALL_KNOWN_SKILLS)

    enabled_hooks = _toggle_enabled(pack_hooks, profile_hook_toggle, ALL_KNOWN_HOOKS)
    enabled_hooks = _toggle_enabled(enabled_hooks, local_hook_toggle, ALL_KNOWN_HOOKS)

    task_focus = local.get("task_focus")
    if task_focus is None:
        task_focus = shared.get("task_focus")

    return {
        "version": int(shared.get("version") or 1),
        "config_format": config_format,
        "shared_config_path": str(shared_yaml_path),
        "local_config_path": str(local_yaml_path),
        "profile": requested_profile if requested_profile in BUILTIN_PROFILES or requested_profile in custom_profiles else default_profile,
        "profile_source": profile_source,
        "default_profile": default_profile,
        "profile_description": str(resolved_profile.get("description") or ""),
        "engine": engine,
        "engine_source": engine_source,
        "work_mode": work_mode,
        "work_mode_source": work_mode_source,
        "mode_profile": WORK_MODE_PROFILES[work_mode],
        "policy_profile": policy_profile,
        "policy_profile_source": policy_profile_source,
        "policy_profile_expectations": POLICY_PROFILES[policy_profile],
        "default_test_scope": engine_default_test_scope(engine, policy_profile) if engine else str(POLICY_PROFILES[policy_profile]["default_test_scope"]),
        "packs": packs,
        "pack_details": {name: PACKS[name] for name in packs},
        "available_profiles": sorted({*BUILTIN_PROFILES.keys(), *custom_profiles.keys()}),
        "available_packs": sorted(PACKS.keys()),
        "available_engines": available_engines,
        "enabled_skills": enabled_skills,
        "enabled_hooks": enabled_hooks,
        "enabled_rules": enabled_rules,
        "task_focus": task_focus,
        "context_capsule": context_capsule,
        "shared_config_exists": shared_yaml_path.is_file(),
        "local_config_exists": local_yaml_path.is_file(),
    }


def emit(payload: Any, pretty: bool) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2 if pretty else None, sort_keys=pretty))


def emit_field(payload: dict[str, Any], field: str) -> None:
    value = payload.get(field, "")
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False, sort_keys=True))
    else:
        print(value)


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve qq profile/config state")
    subparsers = parser.add_subparsers(dest="command", required=False)

    def add_project_arg(target: argparse.ArgumentParser) -> None:
        target.add_argument("--project", default=".", help="Project root (defaults to cwd)")
        target.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    resolve_parser = subparsers.add_parser("resolve", help="Resolve the effective qq config")
    add_project_arg(resolve_parser)

    field_parser = subparsers.add_parser("field", help="Print a single resolved field")
    field_parser.add_argument("field", help="Field name to print")
    field_parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")

    hook_parser = subparsers.add_parser("hook-enabled", help="Print whether a hook is enabled")
    hook_parser.add_argument("hook", help="Hook id")
    hook_parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")

    skill_parser = subparsers.add_parser("skill-enabled", help="Print whether a skill is enabled")
    skill_parser.add_argument("skill", help="Skill id")
    skill_parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")

    args = parser.parse_args()
    command = args.command or "resolve"
    project_dir = Path(getattr(args, "project", ".")).resolve()
    payload = resolve_project_config(project_dir)

    if command == "field":
        emit_field(payload, args.field)
        return 0
    if command == "hook-enabled":
        print("true" if args.hook in payload["enabled_hooks"] else "false")
        return 0
    if command == "skill-enabled":
        print("true" if args.skill in payload["enabled_skills"] else "false")
        return 0

    emit(payload, getattr(args, "pretty", False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
