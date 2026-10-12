#!/usr/bin/env bash
# Stop hook: prevent session exit during an active --auto pipeline.
# Delegates circuit-breaker logic to qq-execute-checkpoint.py pipeline-block.
set -euo pipefail

_qq_self="${BASH_SOURCE[0]//\\//}"; [[ "$_qq_self" == */* ]] || _qq_self="./$_qq_self"
_qq_dir="${_qq_self%/*}"; [[ "$_qq_dir" == /* || "$_qq_dir" == [A-Za-z]:/* ]] || _qq_dir="$PWD/$_qq_dir"   # 纯 bash 取目录，不 fork；Claude Code 在 Windows 上用 C:/… 调钩子，盘符路径也是绝对路径
SCRIPT_DIR="$_qq_dir/.."
source "$SCRIPT_DIR/platform/detect.sh"
source "$SCRIPT_DIR/qq-runtime.sh"

# 快路径：没有进行中的 --auto 流水线就直接放行——先查文件，再起 python 读配置、解析输入。
# 原来顺序反过来，每次收尾都要先起两三个 python，机器一忙就超过 5 秒上限（2026-10-04 实测）。
PROJECT_DIR="$(qq_project_dir)"
PIPELINE_FILE="$PROJECT_DIR/.qq/state/auto-pipeline.json"
[ -f "$PIPELINE_FILE" ] || exit 0

if [ "$(qq_hook_enabled auto_pipeline)" != "true" ]; then
  exit 0
fi

# 提醒一次：这次停是刚被本钩子拦回去之后的再一次（stop_hook_active），就放行——agent 已经被提醒过还有下一步，
# 它仍要停（在等用户、卡住了）就让它停，流水线留着 running，续跑时接着走。
# 原来拿 Python 打印的 True 和 "true" 比，永远不成立，每次都照拦、照计数，三次就熔断成 abandoned。
qq_hook_read_stdin
STOP_ACTIVE="$(qq_hook_input stop_hook_active)"
if [[ "$STOP_ACTIVE" == "true" || "$STOP_ACTIVE" == "True" ]]; then
  exit 0
fi

# 只拦开（或最近推进）这条流水线的会话：审查脚本另起的 claude -p、同一目录里别的会话结束时，pipeline-block 认出
# 不是它的会话就放行、不计数（原来照拦照计数，审查一结束主流水线就离熔断近一步）
qq_session_id || true
RESULT=$($QQ_PY "$SCRIPT_DIR/qq-execute-checkpoint.py" pipeline-block --project "$PROJECT_DIR" --session "${QQ_SESSION_ID:-}" 2>/dev/null || echo '{"action":"allow","reason":"script error"}')

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
