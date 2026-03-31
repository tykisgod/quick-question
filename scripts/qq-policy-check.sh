#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR=""
JSON_MODE=0
FILES=()

if [[ -n "${QQ_PROJECT_DIR:-}" ]]; then
  PROJECT_DIR="$(cd "${QQ_PROJECT_DIR}" && pwd)"
else
  PROJECT_DIR="$PWD"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --project) PROJECT_DIR="$(cd "$2" && pwd)"; shift 2 ;;
    --help|-h)
      cat <<'EOF'
Usage: ./scripts/qq-policy-check.sh [--json] [--project path] [file ...]

If no files are provided, the script checks changed verification-relevant files
for the detected engine.
EOF
      exit 0
      ;;
    *) FILES+=("$1"); shift ;;
  esac
done

ENGINE="$(python3 "$SCRIPT_DIR/qq_engine.py" detect --project "$PROJECT_DIR" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("engine",""))' 2>/dev/null || true)"
if [[ -z "$ENGINE" ]]; then
  echo "Error: no supported engine detected for project: $PROJECT_DIR" >&2
  exit 1
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  mapfile -t FILES < <(python3 - "$PROJECT_DIR" "$ENGINE" "$SCRIPT_DIR/qq_engine.py" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

project_dir = Path(sys.argv[1]).resolve()
engine = sys.argv[2]
engine_script = Path(sys.argv[3]).resolve()

result = subprocess.run(
    ["python3", str(engine_script), "field", "verificationPatterns", "--project", str(project_dir), "--engine", engine],
    check=False,
    capture_output=True,
    text=True,
)

patterns: list[str] = []
if result.returncode == 0 and result.stdout.strip():
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        payload = []
    if isinstance(payload, list):
        patterns = [str(item) for item in payload if str(item)]

files: set[str] = set()
for pattern in patterns:
    for command in (
        ["git", "-C", str(project_dir), "diff", "--name-only", "HEAD", "--", pattern],
        ["git", "-C", str(project_dir), "ls-files", "--others", "--exclude-standard", "--", pattern],
    ):
        run = subprocess.run(command, check=False, capture_output=True, text=True)
        if run.returncode != 0:
            continue
        for line in run.stdout.splitlines():
            token = line.strip()
            if token:
                files.add(token)

for item in sorted(files):
    print(item)
PY
)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  if [[ "$JSON_MODE" -eq 1 ]]; then
    echo "{\"ok\":true,\"engine\":\"$ENGINE\",\"finding_count\":0,\"files_scanned\":[],\"findings\":[]}"
  else
    echo "No verification-relevant files to check."
  fi
  exit 0
fi

python3 - "$PROJECT_DIR" "$ENGINE" "$JSON_MODE" "$SCRIPT_DIR/qq-config.py" "${FILES[@]}" <<'PY'
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

project_dir = Path(sys.argv[1]).resolve()
engine = sys.argv[2]
json_mode = sys.argv[3] == "1"
qq_config_script = Path(sys.argv[4]).resolve()
files = [Path(arg) for arg in sys.argv[5:]]

DEFAULT_RULES = {
    "unity": {
        "find_object_of_type",
        "send_message",
        "tag_compare",
        "get_component_in_hot_path",
    },
    "godot": {
        "get_node_in_hot_path",
        "group_scan_in_hot_path",
    },
}


def load_enabled_rules() -> set[str]:
    enabled = set(DEFAULT_RULES.get(engine) or [])
    if not qq_config_script.is_file():
        return enabled
    result = subprocess.run(
        ["python3", str(qq_config_script), "field", "enabled_rules", "--project", str(project_dir)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return enabled
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return enabled
    if isinstance(payload, list) and payload:
        return {str(item) for item in payload if str(item)}
    return enabled


def add_finding(findings: list[dict[str, Any]], *, rule_id: str, severity: str, file: str, line: int, message: str, suggestion: str) -> None:
    findings.append(
        {
            "rule_id": rule_id,
            "severity": severity,
            "file": file,
            "line": line,
            "message": message,
            "suggestion": suggestion,
        }
    )


def scan_unity_file(path: Path, rel: str, enabled: set[str], findings: list[dict[str, Any]]) -> None:
    method_pattern = re.compile(
        r"^\s*(?:public|private|protected|internal)?\s*(?:override\s+)?(?:static\s+)?(?:IEnumerator|void|[A-Za-z0-9_<>,\[\]?]+)\s+"
        r"(Update|FixedUpdate|LateUpdate|OnCollisionEnter|OnCollisionStay|OnCollisionExit|OnTriggerEnter|OnTriggerStay|OnTriggerExit)\s*\("
    )
    simple_rules = {
        "find_object_of_type": {
            "severity": "critical",
            "pattern": re.compile(r"\bFindObjects?OfType\s*<|\bFindObjects?OfType\s*\("),
            "message": "Runtime code should avoid FindObjectOfType / FindObjectsOfType.",
            "suggestion": "Use registries, cached references, or explicit wiring.",
        },
        "send_message": {
            "severity": "moderate",
            "pattern": re.compile(r"\b(?:SendMessage|BroadcastMessage|SendMessageUpwards)\s*\("),
            "message": "Avoid SendMessage-style reflection dispatch in gameplay code.",
            "suggestion": "Use C# events, UnityEvents, or interface-based dispatch.",
        },
        "tag_compare": {
            "severity": "moderate",
            "pattern": re.compile(r"\.tag\s*==\s*\""),
            "message": "String tag comparisons should use CompareTag().",
            "suggestion": "Replace string tag equality with CompareTag().",
        },
    }

    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    is_editor_file = "/Editor/" in rel or rel.startswith("Editor/")
    current_hot_method = None
    brace_depth = 0
    method_depth = 0

    for idx, line in enumerate(lines, start=1):
        method_match = method_pattern.match(line)
        if method_match:
            current_hot_method = method_match.group(1)
            method_depth = brace_depth + line.count("{") - line.count("}")

        if "get_component_in_hot_path" in enabled and current_hot_method and "GetComponent<" in line:
            add_finding(
                findings,
                rule_id="get_component_in_hot_path",
                severity="critical",
                file=rel,
                line=idx,
                message=f"GetComponent<T>() inside hot path method `{current_hot_method}`.",
                suggestion="Cache the component in Awake/Start or inject it explicitly.",
            )

        for rule_id, rule in simple_rules.items():
            if rule_id not in enabled:
                continue
            if rule_id == "find_object_of_type" and is_editor_file:
                continue
            if rule["pattern"].search(line):
                add_finding(
                    findings,
                    rule_id=rule_id,
                    severity=str(rule["severity"]),
                    file=rel,
                    line=idx,
                    message=str(rule["message"]),
                    suggestion=str(rule["suggestion"]),
                )

        brace_depth += line.count("{") - line.count("}")
        if current_hot_method and brace_depth < method_depth:
            current_hot_method = None
            method_depth = 0


def scan_gdscript_file(path: Path, rel: str, enabled: set[str], findings: list[dict[str, Any]]) -> None:
    hot_method_pattern = re.compile(r"^(\s*)func\s+(_process|_physics_process|_input|_unhandled_input|_unhandled_key_input)\s*\(")
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    current_hot_method = ""
    current_indent = -1

    for idx, line in enumerate(lines, start=1):
        match = hot_method_pattern.match(line)
        if match:
            current_hot_method = match.group(2)
            current_indent = len(match.group(1).replace("\t", "    "))
            continue

        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" \t"))
        if current_hot_method and stripped and not stripped.startswith("#") and indent <= current_indent:
            current_hot_method = ""
            current_indent = -1

        if not current_hot_method:
            continue

        if "get_node_in_hot_path" in enabled and re.search(r"\bget_node\s*\(", line):
            add_finding(
                findings,
                rule_id="get_node_in_hot_path",
                severity="critical",
                file=rel,
                line=idx,
                message=f"get_node() inside hot path method `{current_hot_method}`.",
                suggestion="Cache node references in _ready() or inject them through exported properties.",
            )
        if "group_scan_in_hot_path" in enabled and re.search(r"\b(get_nodes_in_group|get_first_node_in_group)\s*\(", line):
            add_finding(
                findings,
                rule_id="group_scan_in_hot_path",
                severity="moderate",
                file=rel,
                line=idx,
                message=f"Group scan inside hot path method `{current_hot_method}`.",
                suggestion="Cache group members or maintain an explicit registry instead of scanning every frame.",
            )


def scan_godot_csharp_file(path: Path, rel: str, enabled: set[str], findings: list[dict[str, Any]]) -> None:
    method_pattern = re.compile(
        r"^\s*(?:public|private|protected|internal)?\s*(?:override\s+)?(?:void|[A-Za-z0-9_<>,\[\]?]+)\s+"
        r"(_Process|_PhysicsProcess|_Input|_UnhandledInput|_UnhandledKeyInput)\s*\("
    )
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    current_hot_method = ""
    brace_depth = 0
    method_depth = 0

    for idx, line in enumerate(lines, start=1):
        method_match = method_pattern.match(line)
        if method_match:
            current_hot_method = method_match.group(1)
            method_depth = brace_depth + line.count("{") - line.count("}")

        if "get_node_in_hot_path" in enabled and current_hot_method and re.search(r"\bGetNode(?:<[^>]+>)?\s*\(", line):
            add_finding(
                findings,
                rule_id="get_node_in_hot_path",
                severity="critical",
                file=rel,
                line=idx,
                message=f"GetNode() inside hot path method `{current_hot_method}`.",
                suggestion="Cache node references during _Ready() or inject them explicitly.",
            )
        if "group_scan_in_hot_path" in enabled and current_hot_method and re.search(r"\b(GetNodesInGroup|GetFirstNodeInGroup)\s*\(", line):
            add_finding(
                findings,
                rule_id="group_scan_in_hot_path",
                severity="moderate",
                file=rel,
                line=idx,
                message=f"Group scan inside hot path method `{current_hot_method}`.",
                suggestion="Cache group lookups or maintain a registry instead of scanning in a hot path.",
            )

        brace_depth += line.count("{") - line.count("}")
        if current_hot_method and brace_depth < method_depth:
            current_hot_method = ""
            method_depth = 0


enabled = load_enabled_rules()
findings: list[dict[str, Any]] = []
files_scanned: list[str] = []

for file_arg in files:
    path = (project_dir / file_arg).resolve() if not file_arg.is_absolute() else file_arg.resolve()
    if not path.is_file():
        continue
    rel = str(path.relative_to(project_dir))
    files_scanned.append(rel)

    if engine == "unity":
        if path.suffix == ".cs":
            scan_unity_file(path, rel, enabled, findings)
        continue

    if engine == "godot":
        if path.suffix == ".gd":
            scan_gdscript_file(path, rel, enabled, findings)
        elif path.suffix == ".cs":
            scan_godot_csharp_file(path, rel, enabled, findings)
        continue

priority = {"critical": 0, "moderate": 1, "suggestion": 2}
findings.sort(key=lambda item: (priority.get(str(item["severity"]), 9), str(item["file"]), int(item["line"])))

payload = {
    "ok": len(findings) == 0,
    "engine": engine,
    "finding_count": len(findings),
    "files_scanned": files_scanned,
    "findings": findings,
}

if json_mode:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    raise SystemExit(0)

groups = {
    "critical": "## Critical",
    "moderate": "## Moderate",
    "suggestion": "## Suggestions",
}

printed_any = False
for severity in ("critical", "moderate", "suggestion"):
    matches = [item for item in findings if item["severity"] == severity]
    if not matches:
        continue
    printed_any = True
    print(groups[severity])
    for item in matches:
        print(f"- [{item['file']}:{item['line']}] {item['message']} -> {item['suggestion']}")
    print()

if not printed_any:
    print("## Deterministic Policy Checks")
    print("- No deterministic policy violations found.")
PY
