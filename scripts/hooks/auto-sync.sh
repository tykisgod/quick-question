#!/usr/bin/env bash
# SessionStart hook [startup]: auto-sync project scripts after plugin upgrade
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# 配置写坏时，可开关的钩子一律按「关」处理（qq_hook_enabled 拿到非 0 就当 false），而那些钩子退 0 时
# stderr 没人看得见。SessionStart 的 stdout 会进会话上下文，所以每次开会话都在这里检查一遍配置，
# 解析不了就把原因打到 stdout，免得钩子悄悄全关、要等有人跑 /qq:go 才发现。
# 配置坏了同步也做不成（安装计划要读配置），这次跳过，修好后下次开会话再同步。
if [ -f "$PROJECT_DIR/qq.yaml" ] || [ -f "$PROJECT_DIR/.qq/local.yaml" ]; then
  QQ_CONFIG_ERROR="$($QQ_PY "$(dirname "${BASH_SOURCE[0]}")/../qq-config.py" resolve --project "$PROJECT_DIR" 2>&1 >/dev/null)" || {
    # 取最后一个非空行：ConfigError 本来就只有一行；万一是别的异常，traceback 的最后一行最有用
    QQ_CONFIG_ERROR="$(printf '%s\n' "$QQ_CONFIG_ERROR" | sed '/^[[:space:]]*$/d' | tail -n 1)"
    QQ_CONFIG_ERROR="${QQ_CONFIG_ERROR#qq-config: error: }"
    echo "[qq] Config error: ${QQ_CONFIG_ERROR:-qq-config.py resolve failed}"
    echo "[qq] Until it is fixed, qq treats its switchable hooks (auto_compile, compile_gate, review_gate, skill_review, auto_pipeline) as off, qq's git pre-push hook (if installed) blocks pushes, and script sync is skipped. Tell the user, fix the file, then check with: python3 scripts/qq-config.py resolve"
    exit 0
  }
fi

[ -d "$PROJECT_DIR/.qq" ] || exit 0

$QQ_PY "$(dirname "${BASH_SOURCE[0]}")/../qq-auto-sync.py" \
  --project "$PROJECT_DIR" \
  --plugin-root "${CLAUDE_PLUGIN_ROOT}"
