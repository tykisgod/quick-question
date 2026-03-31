#!/usr/bin/env bash
# qq-policy-check.sh — deterministic Unity policy checks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR=""

if [[ -n "${QQ_PROJECT_DIR:-}" && -f "${QQ_PROJECT_DIR}/ProjectSettings/ProjectVersion.txt" ]]; then
  PROJECT_DIR="$(cd "${QQ_PROJECT_DIR}" && pwd)"
elif [[ -f "$PWD/ProjectSettings/ProjectVersion.txt" ]]; then
  PROJECT_DIR="$PWD"
elif [[ -f "$SCRIPT_DIR/../ProjectSettings/ProjectVersion.txt" ]]; then
  PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$GIT_ROOT" && -f "$GIT_ROOT/ProjectSettings/ProjectVersion.txt" ]]; then
    PROJECT_DIR="$GIT_ROOT"
  else
    PROJECT_DIR="$PWD"
  fi
fi
JSON_MODE=0
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --project) PROJECT_DIR="$(cd "$2" && pwd)"; shift 2 ;;
    --help|-h)
      cat <<'EOF'
Usage: ./scripts/qq-policy-check.sh [--json] [--project path] [file1.cs file2.cs ...]

If no files are provided, the script checks changed .cs files from git diff + untracked files.
EOF
      exit 0
      ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] && FILES+=("$file")
  done < <(
    {
      git -C "$PROJECT_DIR" diff --name-only HEAD -- '*.cs' 2>/dev/null || true
      git -C "$PROJECT_DIR" ls-files --others --exclude-standard -- '*.cs' 2>/dev/null || true
    } | sort -u
  )
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  if [[ "$JSON_MODE" -eq 1 ]]; then
    echo '{"ok":true,"finding_count":0,"files_scanned":[],"findings":[]}'
  else
    echo "No .cs files to check."
  fi
  exit 0
fi

python3 - "$PROJECT_DIR" "$JSON_MODE" "$SCRIPT_DIR/qq-config.py" "${FILES[@]}" <<'PY'
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

project_dir = Path(sys.argv[1]).resolve()
json_mode = sys.argv[2] == "1"
qq_config_script = Path(sys.argv[3]).resolve()
files = [Path(arg) for arg in sys.argv[4:]]

default_enabled = {
    "find_object_of_type",
    "send_message",
    "tag_compare",
    "get_component_in_hot_path",
}
enabled = set(default_enabled)

if qq_config_script.is_file():
    result = subprocess.run(
        ["python3", str(qq_config_script), "field", "enabled_rules", "--project", str(project_dir)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0 and result.stdout.strip():
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError:
            payload = []
        if isinstance(payload, list) and payload:
            enabled = {str(item) for item in payload}

method_pattern = re.compile(
    r"^\s*(?:public|private|protected|internal)?\s*(?:override\s+)?(?:static\s+)?(?:IEnumerator|void|[A-Za-z0-9_<>,\[\]?]+)\s+"
    r"(Update|FixedUpdate|LateUpdate|OnCollisionEnter|OnCollisionStay|OnCollisionExit|OnTriggerEnter|OnTriggerStay|OnTriggerExit)\s*\("
)

rules = {
    "find_object_of_type": {
        "severity": "critical",
        "pattern": re.compile(r"\bFindObjects?OfType\s*<|\bFindObjects?OfType\s*\("),
        "message": "Runtime code should avoid FindObjectOfType / FindObjectsOfType.",
        "suggestion": "Use project registries, cached references, or explicit wiring.",
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
        "suggestion": "Replace `obj.tag == \"X\"` with `obj.CompareTag(\"X\")`.",
    },
}

findings: list[dict[str, object]] = []
files_scanned: list[str] = []

for file_arg in files:
    path = (project_dir / file_arg).resolve() if not file_arg.is_absolute() else file_arg.resolve()
    if not path.is_file():
        continue
    if path.suffix != ".cs":
        continue

    rel = str(path.relative_to(project_dir))
    files_scanned.append(rel)
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
            findings.append(
                {
                    "rule_id": "get_component_in_hot_path",
                    "severity": "critical",
                    "file": rel,
                    "line": idx,
                    "message": f"GetComponent<T>() inside hot path method `{current_hot_method}`.",
                    "suggestion": "Cache component references in Awake/Start or inject them explicitly.",
                }
            )

        for rule_id, rule in rules.items():
            if rule_id not in enabled:
                continue
            if rule_id == "find_object_of_type" and is_editor_file:
                continue
            if rule["pattern"].search(line):
                findings.append(
                    {
                        "rule_id": rule_id,
                        "severity": rule["severity"],
                        "file": rel,
                        "line": idx,
                        "message": rule["message"],
                        "suggestion": rule["suggestion"],
                    }
                )

        brace_depth += line.count("{") - line.count("}")
        if current_hot_method and brace_depth < method_depth:
            current_hot_method = None
            method_depth = 0

priority = {"critical": 0, "moderate": 1, "suggestion": 2}
findings.sort(key=lambda item: (priority.get(str(item["severity"]), 9), str(item["file"]), int(item["line"])))

payload = {
    "ok": len(findings) == 0,
    "finding_count": len(findings),
    "files_scanned": files_scanned,
    "findings": findings,
}

if json_mode:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    raise SystemExit(0)

groups = {
    "critical": "## 🔴 Critical",
    "moderate": "## 🟠 Moderate",
    "suggestion": "## 🟡 Suggestions",
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
    print("## ✅ Deterministic Policy Checks")
    print("- No deterministic policy violations found.")
PY
