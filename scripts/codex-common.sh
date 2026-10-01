#!/usr/bin/env bash
# codex-common.sh — Shared Codex CLI helpers for code-review.sh / plan-review.sh.
# Source this file; it defines functions only. qq_codex_run toggles errexit internally and restores it.
#
#   qq_codex_resolve_effort <requested>   -> sets QQ_CODEX_EFFORT_RESOLVED ("" = inherit config.toml)
#   qq_codex_run <prompt-file> <out-file> -> runs `codex exec`, tees stdout, returns non-zero on failure
#
# 推理强度：
#   - 显式（--effort / QQ_CODEX_EFFORT）按 codex 实际会用的模型所支持的档位校验后透传；值为 `config` 时沿用 config.toml。
#   - 未指定时取该模型支持的最高档（审查要最深的推理）。config.toml 里的强度常是桌面端交互用的低档，
#     不再跟随它——跟随会让审查悄悄降成 low。
#   - 模型按 codex 自己的规则取：从当前目录往上找到的项目级 .codex/config.toml 里的 `model` 优先，
#     否则 $CODEX_HOME（默认 ~/.codex；Windows 上家目录按 USERPROFILE，与 codex 一致）下 config.toml 顶层的 `model`。
#     旧写法的顶层 `profile` 键与 [profiles.<名>] 段 codex 0.134 起已不生效（profile 改为 --profile 叠加
#     $CODEX_HOME/<名>.config.toml），本脚本不传 --profile，所以也不看它们。
#     项目级配置在 codex 里只对「已信任」的项目生效；这里不核对信任状态，偏宽一点——只影响强度的校验与默认档。
#     档位从 $CODEX_HOME/models_cache.json 读；读不到时退回 high。
# 提示词走 stdin，不走 argv：Windows 上长 argv 会被截断（实测 4563 字符只收到 796），codex 会答非所问。
# codex 及其沙箱里的 shell 一律带 GIT_OPTIONAL_LOCKS=0，免得只读沙箱里的 `git status` 留下陈旧的 .git/index.lock。

_QQ_CODEX_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${QQ_PY:-}" ]]; then
  # shellcheck source=platform/detect.sh
  source "$_QQ_CODEX_COMMON_DIR/platform/detect.sh"
fi

# 档位从低到高；未知档位排在最前（不会被当成最高档选中）。
QQ_CODEX_EFFORT_ORDER="none minimal low medium high xhigh max ultra"

# 打印两行：第一行是 codex 实际会用的模型（取不到为空），第二行是它支持的档位（空格分隔，取不到为空）。
qq_codex_model_info() {
  "$QQ_PY" - <<'PY' 2>/dev/null || printf '\n\n'
import json, os, re

home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def top_level_model(path):
    """config.toml 顶层的 model（任何 [段] 之前），取不到为 None。"""
    try:
        with open(path, "rb") as fh:
            text = fh.read().decode("utf-8")
    except (OSError, ValueError):
        return None
    try:
        import tomllib  # Python 3.11+
        try:
            value = tomllib.loads(text).get("model")
        except ValueError:
            return None
        return value if isinstance(value, str) and value else None
    except ImportError:
        # 旧版 Python 没有 tomllib：只认顶层的 model = "..." / '...'
        for line in text.splitlines():
            line = line.split("#", 1)[0].strip()
            if line.startswith("["):
                return None
            m = re.match(r"""^model\s*=\s*(?:"([^"]*)"|'([^']*)')""", line)
            if m:
                value = m.group(1) if m.group(1) is not None else m.group(2)
                return value or None
        return None


# 用户级配置（$CODEX_HOME 的，以及家目录下默认 .codex 的）不算项目级配置，往上找时跳过
user_cfgs = {os.path.normcase(os.path.abspath(os.path.join(p, "config.toml")))
             for p in (home, os.path.join(os.path.expanduser("~"), ".codex"))}
model = None
d = os.path.abspath(os.getcwd())
while True:
    candidate = os.path.join(d, ".codex", "config.toml")
    if os.path.normcase(candidate) not in user_cfgs and os.path.isfile(candidate):
        model = top_level_model(candidate)
        break
    parent = os.path.dirname(d)
    if parent == d:
        break
    d = parent
if not model:
    model = top_level_model(os.path.join(home, "config.toml")) or ""

levels = []
try:
    with open(os.path.join(home, "models_cache.json"), encoding="utf-8") as fh:
        data = json.load(fh)
    for m in data.get("models", []):
        if isinstance(m, dict) and m.get("slug") == model:
            levels = [lv.get("effort") for lv in m.get("supported_reasoning_levels", [])
                      if isinstance(lv, dict) and lv.get("effort")]
            break
except (OSError, ValueError):
    pass

print(model)
print(" ".join(levels))
PY
}

# 在给定档位里挑最高的一档。
qq_codex_highest_effort() {
  local best="" best_rank=-1 e o rank i
  for e in "$@"; do
    rank=-1; i=0
    for o in $QQ_CODEX_EFFORT_ORDER; do
      [[ "$o" == "$e" ]] && rank=$i
      i=$((i + 1))
    done
    if (( rank > best_rank )); then best="$e"; best_rank=$rank; fi
  done
  printf '%s' "$best"
}

qq_codex_resolve_effort() {
  local requested="$1" info model supported
  info="$(qq_codex_model_info)"
  model="$(printf '%s\n' "$info" | sed -n 1p)"
  supported="$(printf '%s\n' "$info" | sed -n 2p)"

  if [[ "$requested" == "config" ]]; then
    QQ_CODEX_EFFORT_RESOLVED=""
    return 0
  fi

  if [[ -n "$requested" ]]; then
    if [[ -n "$supported" ]]; then
      if [[ " $supported " != *" $requested "* ]]; then
        echo "Error: effort '$requested' is not supported by model '${model}' (supported: ${supported// /, }; or 'config' to inherit config.toml)" >&2
        return 1
      fi
    elif [[ " $QQ_CODEX_EFFORT_ORDER " != *" $requested "* ]]; then
      echo "Error: unknown effort '$requested' (expected one of: ${QQ_CODEX_EFFORT_ORDER// /, }; or 'config')" >&2
      return 1
    fi
    QQ_CODEX_EFFORT_RESOLVED="$requested"
    return 0
  fi

  if [[ -n "$supported" ]]; then
    # shellcheck disable=SC2086
    QQ_CODEX_EFFORT_RESOLVED="$(qq_codex_highest_effort $supported)"
  else
    QQ_CODEX_EFFORT_RESOLVED="high"
  fi
}

# 跑一次 codex exec：提示词从文件走 stdin；stdout（审查结论）实时上终端并写进 out-file；
# stderr（进度与报错）先落临时文件、codex 结束后整体回显——不用进程替换，收尾时没有还在写的后台进程。
# codex 失败或 out-file 写不进去都返回非零；codex 失败且是「CLI 太旧不认识配置里的模型」时额外给升级提示
# （只在失败时认这条报错：成功的审查结论或 codex 打印的工具输出里也可能出现这句原文）。
qq_codex_run() {
  local prompt_file="$1" out_file="$2" err_file had_errexit=0 codex_status tee_status
  local -a effort_args=() statuses=()
  [[ -n "${QQ_CODEX_EFFORT_RESOLVED:-}" ]] && effort_args=(-c "model_reasoning_effort=\"${QQ_CODEX_EFFORT_RESOLVED}\"")
  err_file="$(mktemp "${QQ_TEMP_DIR:-/tmp}/qq-codex-err.XXXXXX")"
  [[ $- == *e* ]] && had_errexit=1
  set +e
  # GIT_OPTIONAL_LOCKS=0：codex 审查时常跑 `git status`，git 会顺手拿 .git/index.lock 回写刷新过的索引；
  # 只读沙箱里这把锁建得出来却删不掉，留下 0 字节的陈旧锁，挡住之后所有的 git 提交。
  # 两处都设：进程环境给 codex 自己，shell_environment_policy 保证沙箱里起的 shell 也拿到。
  GIT_OPTIONAL_LOCKS=0 codex exec --sandbox read-only -c 'shell_environment_policy.set.GIT_OPTIONAL_LOCKS="0"' \
    ${effort_args[@]+"${effort_args[@]}"} < "$prompt_file" 2> "$err_file" | tee "$out_file"
  statuses=("${PIPESTATUS[@]}")
  (( had_errexit )) && set -e
  codex_status=${statuses[0]}
  tee_status=${statuses[1]:-0}
  cat "$err_file" >&2
  if (( codex_status != 0 )) && grep -q "is not supported when using Codex with a ChatGPT account" "$err_file"; then
    echo "" >&2
    echo ">>> Codex rejected the configured model ($(qq_codex_model_info | sed -n 1p))." >&2
    echo ">>> The usual cause is an outdated CLI ($(codex --version 2>/dev/null | head -1)) that predates the model;" >&2
    echo ">>> the desktop app may already bundle a newer one. Update: npm i -g @openai/codex@latest" >&2
  fi
  rm -f "$err_file"
  if (( codex_status != 0 )); then
    return "$codex_status"
  fi
  if (( tee_status != 0 )); then
    echo "Error: could not write the review to ${out_file}" >&2
    return "$tee_status"
  fi
  return 0
}
