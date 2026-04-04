#!/usr/bin/env bash
# Stop hook: prevent session exit during an active --auto pipeline.
# Delegates circuit-breaker logic to qq-execute-checkpoint.py pipeline-block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/platform/detect.sh"
source "$SCRIPT_DIR/qq-runtime.sh"

if [ "$(qq_hook_enabled auto_pipeline)" != "true" ]; then
  exit 0
fi

# Prevent infinite recursion when Stop hooks re-trigger
INPUT=$(cat)
STOP_ACTIVE=$(echo "$INPUT" | $QQ_PY -c "import json,sys; print(json.load(sys.stdin).get('stop_hook_active','false'))" 2>/dev/null || echo "false")
if [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

PROJECT_DIR="$(qq_project_dir)"
PIPELINE_FILE="$PROJECT_DIR/.qq/state/auto-pipeline.json"
[ -f "$PIPELINE_FILE" ] || exit 0

# Delegate to checkpoint script for circuit-breaker logic
RESULT=$($QQ_PY "$SCRIPT_DIR/qq-execute-checkpoint.py" pipeline-block --project "$PROJECT_DIR" 2>/dev/null || echo '{"action":"allow","reason":"script error"}')

ACTION=$(echo "$RESULT" | $QQ_PY -c "import json,sys; print(json.load(sys.stdin).get('action','allow'))" 2>/dev/null || echo "allow")

if [ "$ACTION" = "block" ]; then
  CURRENT=$(echo "$RESULT" | $QQ_PY -c "import json,sys; d=json.load(sys.stdin); print(d.get('current_skill',''))" 2>/dev/null)
  COMPLETED=$(echo "$RESULT" | $QQ_PY -c "import json,sys; d=json.load(sys.stdin); print(' -> '.join(d.get('completed_skills',[])))" 2>/dev/null)
  ITERATION=$(echo "$RESULT" | $QQ_PY -c "import json,sys; d=json.load(sys.stdin); print(f\"{d.get('iteration',0)}/{d.get('max_iterations',20)}\")" 2>/dev/null)
  RESUME=$(echo "$RESULT" | $QQ_PY -c "import json,sys; print(json.load(sys.stdin).get('resume_command',''))" 2>/dev/null)

  REASON="BLOCKED: --auto pipeline is still running (iteration ${ITERATION}). DO NOT stop.
Completed: ${COMPLETED:-none}
Next: ${CURRENT}
Resume: invoke ${RESUME}
You MUST invoke the skill shown above using the Skill tool. Do not ask the user — this is --auto mode."

  echo "{\"decision\":\"block\",\"reason\":$(echo "$REASON" | $QQ_PY -c "import json,sys; print(json.dumps(sys.stdin.read()))")}"
  exit 0
fi

# Allow exit
exit 0
