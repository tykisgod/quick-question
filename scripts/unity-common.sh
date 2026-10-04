#!/usr/bin/env bash
# unity-common.sh — Unity 脚本公共函数
# 被 unity-compile-smart.sh, unity-check.sh, unity-test.sh, unity-compile.sh 共享
#
# 使用方式: source "$(dirname "$0")/unity-common.sh"
# 前提: 调用方必须先设置 PROJECT_DIR 变量

# ── 加载平台检测层 ──
source "$(dirname "${BASH_SOURCE[0]}")/platform/detect.sh"

# ── 检测 Unity Editor 是否为当前项目打开 ──
#
# 返回码三档，调用方必须把后两档分开对待：
#   0  确认有 Editor 打开着本项目
#   1  确认没有 Editor 打开本项目 —— 可以放心走 -batchmode
#   2  探测不出结论 —— 有人持着本项目的锁，但没有一条判据认得出他是谁
#
# 为什么要拆出第 2 档：这个函数是整条静默降级链的总闸。原来"判不出"和"确认没开"都压成 1，
# 调用方一律读成"没开"，于是自动改走 -batchmode 去抢一个很可能正开着的 Editor 的项目锁——
# 轻则拿到的编译/测试判据不可信，重则两个 Unity 同时写 Library 把导入缓存搞坏。
# 而"判不出"恰恰是常态而非意外：wmic.exe 自 Win11 24H2 起被微软移除，进程归属判据永久失效；
# 它的兜底判据读的又是 tykit 写的 Temp/compile_status.json，tykit 一从项目里移除就一并消失。
# 代价不对称 —— 猜错方向是抢锁事故，猜对也只省一次提问 —— 所以宁可吵着退非 0，
# 把"要不要拿 batchmode 去撞锁"的决定权交还给人。
#
# 正向判据一是 Unity 官方 Pipeline 的描述文件（qq_unity_pipeline_probe），二是平台层的进程探测。
is_editor_open_for_project() {
    # 正向判据一：Library/Pipeline/.unity-pipeline-port 有效 —— 读得出、projectPath 是本项目、里面的 pid 活着。
    #
    # 这个判据**天然按项目限定**：描述文件在 <项目>/Library/ 下，而且自带 projectPath，
    # 两者对上才算数（拷 Library 时带过来的别的项目的描述文件不算）；pid 已死的陈旧描述文件也不算。
    # 和「用不用官方 CLI 通道」（qq_unity_channel）看的是同一份证据，两处不会各说各话。
    #
    # 这里原来把 $PROJECT_DIR 拼进 python -c 的代码字符串再 curl 端口：Git Bash 不转换代码字符串里的路径，
    # /e/… 在原生 python 里变成 E:\e\…，cd && pwd 得到 /e/… 的调用方（unity-test.sh、unity-check.sh）
    # 在 Windows 上永远判不成立；curl 又会被本机 HTTP_PROXY 拖慢。现在路径作为独立参数传给 python，
    # 不发网络请求；描述文件里的令牌一个字节都不碰（qq-unity-cli.py probe 只按字段取 pid/port/projectPath）。
    if qq_unity_pipeline_probe; then
        return 0
    fi

    # 正向判据二：平台层。它才是本平台的权威 —— 什么算证据、证据够不够，只有它知道。
    qq_is_unity_running "$PROJECT_DIR"
    local rc=$?

    # 平台层能自陈"传感器坏了"的（platform/windows.sh 即是），用 ≥2 表达。
    # 这一档必须原样往上传：把它压回 1 就是在替一个坏掉的读数签"可以去抢锁了"的字。
    # 注意 127（函数没定义）也落在这一档，同样是判不出，不是没开。
    if [ "$rc" -ge 2 ]; then
        return 2
    fi

    # 本平台压根没有实现（detect.sh 找不到 <platform>.sh 时只挂了个恒返回 1 的桩，
    # QQ_PLATFORM=linux/unknown 就走这条，由 QQ_PLATFORM_IMPL=0 标出）。那个 1 不是探测结论，
    # 是"根本没人探测过"，照单全收等于把"没实现"读成"没开"，又是一次静默降级。
    #
    # 此时唯一还能自证的负向事实是 UnityLockfile：它由 Unity 自己在打开项目期间持有
    # （Editor 用它判"这个项目已经被打开了"），不依赖任何平台探测工具就能读。
    # 它不在 ⇒ 没人持有本项目，"确认没开"成立，CI 那种干净机器照常走 batch；
    # 它在 ⇒ 有人持锁而我们无从辨认，只能判不出。
    if [ "$rc" -eq 1 ] && [ "$QQ_PLATFORM_IMPL" -eq 0 ] &&
       [ -f "$PROJECT_DIR/Temp/UnityLockfile" ]; then
        echo "[qq] ❌ 判不出 Unity Editor 是否打开了本项目：本平台没有探测实现" >&2
        echo "[qq]    平台: $QQ_PLATFORM（scripts/platform/${QQ_PLATFORM}.sh 不存在，用的是恒返回「没在跑」的桩）" >&2
        echo "[qq]    项目: $PROJECT_DIR" >&2
        echo "[qq]    本项目的 Temp/UnityLockfile 还在，说明有进程持着它，Editor 很可能正开着。" >&2
        echo "[qq]    据此报「没开」，调用方就会用 -batchmode 另起一个 Unity 抢同一把锁。" >&2
        echo "[qq]    确认本机没有 Editor 持有本项目后，用调用方的显式 batch 开关（如 --batch）重跑。" >&2
        return 2
    fi

    return "$rc"
}

# ── 查找 Unity Editor 可执行文件路径 ──
find_unity() {
    qq_find_unity_binary "$PROJECT_DIR"
}

# ── 查找 tykit 的 unity-eval.sh（兼容 PackageCache 和嵌入包） ──
find_unity_eval() {
    # 优先搜嵌入包
    local embedded="$PROJECT_DIR/Packages/com.tyk.tykit/Scripts~/unity-eval.sh"
    if [ -f "$embedded" ]; then
        echo "$embedded"
        return
    fi

    # 回退搜 PackageCache
    find "$PROJECT_DIR/Library/PackageCache" -name "unity-eval.sh" -path "*/com.tyk.tykit*" 2>/dev/null | head -1
}

# ── 获取 tykit 端口 ──
get_tykit_port() {
    local json_file="$PROJECT_DIR/Temp/tykit.json"
    if [ -f "$json_file" ]; then
        local py_cmd="python3"
        python3 --version >/dev/null 2>&1 || py_cmd="python"
        $py_cmd -c "import json; print(json.load(open('$json_file'))['port'])" 2>/dev/null
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Unity 官方 CLI 通道（`unity command` / `unity job`，Pipeline 包 com.unity.pipeline）
#
#  通道判定（qq_unity_channel）：
#    0. 环境变量 QQ_UNITY_CHANNEL=unity-cli|tykit|refresh-trigger|none 直接指定
#    1. 描述文件有效（Library/Pipeline/.unity-pipeline-port 读得出、属于本项目、pid 活着）且找得到 CLI → unity-cli
#    2. 描述文件有效但找不到 CLI → 有 tykit（判据同 3）就回落 tykit；否则编译走 refresh-trigger（不激活窗口：
#       Pipeline 在失焦时也会 tick），测试 none（unity_cli_unavailable）
#    3. 有 Temp/tykit.json（编译还要找得到 unity-eval.sh，测试还要 is_editor_open_for_project 成立）→ tykit
#    4. 其余：编译走 refresh-trigger（旧行为，会激活窗口），测试 none
#  判通道时不发任何网络请求，也不跑 `unity --version`（一次要 1.5–2 秒）：第一次 CLI 调用自然会证明服务在不在。
#
#  🔴 描述文件里的令牌等于在 Editor 里执行任意 C# 的权限：只许 qq-unity-cli.py 按字段读 port / pid / projectPath，
#     不要 cat / grep / sed / jq 这个文件，也不要把它的内容放进任何输出。
#
#  CLI 只在 bash 里调（Windows 上 python 的 subprocess 跑不了没有扩展名的程序）；回包写进文件，交给
#  qq-unity-cli.py 判，bash 不碰 JSON。测试（unity-test.sh 的官方跑法）复用这里的通道判定和 qq_ucli*。
# ══════════════════════════════════════════════════════════════════
QQ_UNITY_CLI_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qq-unity-cli.py"

# Windows 上转成 E:/… 形式（交给原生程序、又关掉了 MSYS 自动转换时用），其它平台原样返回
qq_unity_native_path() {
    local p="$1"
    case "$p" in
        /*|[A-Za-z]:[\\/]*) ;;
        *) p="$(cd "$p" 2>/dev/null && pwd || printf '%s' "$p")" ;;
    esac
    if [ "${QQ_PLATFORM:-}" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$p"
    else
        printf '%s\n' "$p"
    fi
}

# 定位 CLI 可执行文件，设 QQ_UNITY_CLI_BIN；找不到返回 1。QQ_UNITY_CLI 优先（测试用它指向桩）。
# 不能像 python3 那样跳过 WindowsApps：Windows 上的 unity 就是装在那里的应用别名，是真能用的程序。
qq_unity_cli_bin() {
    local bin="${QQ_UNITY_CLI:-}" probe
    [ -n "$bin" ] || bin="$(command -v unity 2>/dev/null || true)"
    [ -n "$bin" ] && [ -e "$bin" ] || return 1
    # 大小写不敏感的文件系统上，PATH 里的 Unity Editor 本体也会被 `command -v unity` 找到，不能当 CLI。
    # 比对前统一成 / 分隔、小写（QQ_UNITY_CLI 可能写成 C:\…\Editor\Unity.exe）；qq-unity-cli.py 的 _EDITOR_BINARY 是同一条规则
    probe="$(printf '%s' "$bin" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')"
    case "$probe" in
        */unity.app/*|*/editor/unity|*/editor/unity.exe) return 1 ;;
    esac
    QQ_UNITY_CLI_BIN="$bin"
}

# 描述文件有效（读得出、属于本项目、pid 活着）时返回 0，并设 QQ_UNITY_PIPELINE_PORT / QQ_UNITY_PIPELINE_PID。
# 无效时返回 1，QQ_UNITY_PIPELINE_PROBE_REASON 是一个固定的原因词。同一个进程里只探一次。
qq_unity_pipeline_probe() {
    case "${QQ_UNITY_PIPELINE_PROBED:-}" in
        ok) return 0 ;;
        fail) return 1 ;;
    esac
    QQ_UNITY_PIPELINE_PORT=""
    QQ_UNITY_PIPELINE_PID=""
    QQ_UNITY_PIPELINE_PROBE_REASON=""
    QQ_UNITY_PIPELINE_PROBED=fail
    # 先用 [ -f ] 判在不在（不读内容）：没有描述文件的项目不必起 python
    if [ ! -f "$PROJECT_DIR/Library/Pipeline/.unity-pipeline-port" ]; then
        QQ_UNITY_PIPELINE_PROBE_REASON=missing
        return 1
    fi
    if [ ! -f "$QQ_UNITY_CLI_PY" ]; then
        QQ_UNITY_PIPELINE_PROBE_REASON=helper-missing
        return 1
    fi
    local out="" rc=0 port="" pid="" rest=""
    # 成功时 stdout 只有 "<port> <pid>"，失败时 stderr 只有一个原因词，所以合在一起读是安全的
    out="$("$QQ_PY" "$QQ_UNITY_CLI_PY" probe --project "$PROJECT_DIR" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$out" in
            missing|unreadable|foreign-project|pid-dead) QQ_UNITY_PIPELINE_PROBE_REASON="$out" ;;
            *) QQ_UNITY_PIPELINE_PROBE_REASON=probe-error ;;   # 其它输出一律不转述
        esac
        return 1
    fi
    read -r port pid rest <<EOF
$out
EOF
    case "$port" in ''|*[!0-9]*) QQ_UNITY_PIPELINE_PROBE_REASON=probe-error; return 1 ;; esac
    case "$pid" in ''|*[!0-9]*) QQ_UNITY_PIPELINE_PROBE_REASON=probe-error; return 1 ;; esac
    QQ_UNITY_PIPELINE_PORT="$port"
    QQ_UNITY_PIPELINE_PID="$pid"
    QQ_UNITY_PIPELINE_PROBED=ok
    return 0
}

# qq_unity_channel <compile|test>：结果放在全局变量 QQ_UNITY_CHANNEL_RESOLVED（unity-cli | tykit | refresh-trigger | none），
# QQ_UNITY_CHANNEL_REASON 说明为什么（forced / pipeline-descriptor / unity_cli_unavailable / editor_not_detected）。
# 不 echo 结果：$(…) 跑在子 shell 里，里面设的 QQ_UNITY_CLI_BIN、探测缓存都带不回来。
qq_unity_channel() {
    local kind="${1:-compile}"
    QQ_UNITY_CHANNEL_RESOLVED=""
    QQ_UNITY_CHANNEL_REASON=""
    case "${QQ_UNITY_CHANNEL:-}" in
        "") ;;
        unity-cli)
            if qq_unity_cli_bin; then
                QQ_UNITY_CHANNEL_RESOLVED=unity-cli
                QQ_UNITY_CHANNEL_REASON=forced
                return 0
            fi
            echo "[qq] QQ_UNITY_CHANNEL=unity-cli, but the Unity CLI executable was not found (set QQ_UNITY_CLI or install the Unity CLI)" >&2
            _qq_unity_channel_cli_missing "$kind"
            return 0
            ;;
        tykit|refresh-trigger|none)
            QQ_UNITY_CHANNEL_RESOLVED="$QQ_UNITY_CHANNEL"
            QQ_UNITY_CHANNEL_REASON=forced
            return 0
            ;;
        *)
            echo "[qq] Ignoring invalid QQ_UNITY_CHANNEL=${QQ_UNITY_CHANNEL} (expected unity-cli|tykit|refresh-trigger|none)" >&2
            ;;
    esac

    if qq_unity_pipeline_probe; then
        if qq_unity_cli_bin; then
            QQ_UNITY_CHANNEL_RESOLVED=unity-cli
            QQ_UNITY_CHANNEL_REASON=pipeline-descriptor
            return 0
        fi
        echo "[qq] This project has a live Unity Pipeline descriptor, but the Unity CLI (unity) was not found: set QQ_UNITY_CLI to its path, or install the Unity CLI" >&2
        _qq_unity_channel_cli_missing "$kind"
        return 0
    fi
    case "${QQ_UNITY_PIPELINE_PROBE_REASON:-}" in
        ""|missing) ;;
        *) echo "[qq] Library/Pipeline/.unity-pipeline-port is not usable (${QQ_UNITY_PIPELINE_PROBE_REASON}); not using the official Unity CLI channel" >&2 ;;
    esac

    if [ -f "$PROJECT_DIR/Temp/tykit.json" ]; then
        if [ "$kind" = test ]; then
            if is_editor_open_for_project; then
                QQ_UNITY_CHANNEL_RESOLVED=tykit
                return 0
            fi
        elif [ -n "$(find_unity_eval)" ]; then
            QQ_UNITY_CHANNEL_RESOLVED=tykit
            return 0
        fi
    fi

    if [ "$kind" = test ]; then
        QQ_UNITY_CHANNEL_RESOLVED=none
        QQ_UNITY_CHANNEL_REASON=editor_not_detected
    else
        QQ_UNITY_CHANNEL_RESOLVED=refresh-trigger
    fi
}

# 描述文件有效、找不到 CLI：项目还装着 tykit（Temp/tykit.json，判据同优先级 3）就回落 tykit——描述文件出现之前
# 它就是能用的通道（典型是正从 tykit 迁到官方 CLI、或者 CLI 不在钩子的 PATH 上），不能因为多了个 Pipeline 就拒跑测试。
# 没有 tykit：编译照旧写 refresh_trigger（Pipeline 在失焦时也 tick，不用激活窗口），测试没有通道
_qq_unity_channel_cli_missing() {
    QQ_UNITY_CHANNEL_REASON=unity_cli_unavailable
    if [ -f "$PROJECT_DIR/Temp/tykit.json" ]; then
        if { [ "$1" = test ] && is_editor_open_for_project; } || { [ "$1" != test ] && [ -n "$(find_unity_eval)" ]; }; then
            echo "[qq] Falling back to tykit (Temp/tykit.json) for this ${1}" >&2
            QQ_UNITY_CHANNEL_RESOLVED=tykit
            return 0
        fi
    fi
    if [ "$1" = test ]; then
        QQ_UNITY_CHANNEL_RESOLVED=none
    else
        QQ_UNITY_CHANNEL_RESOLVED=refresh-trigger
    fi
}

# 写 refresh_trigger 之后要不要把 Unity 窗口拉到前台：Pipeline 在跑（描述文件有效）时 Editor 失焦也照常 tick，不拉；
# QQ_UNITY_NO_FOCUS=1 时也不拉。其余情况沿用旧行为（Editor 在后台时 update 循环未必 tick）。
qq_unity_maybe_activate_window() {
    if [ "${QQ_UNITY_NO_FOCUS:-0}" = 1 ]; then
        echo "[qq] QQ_UNITY_NO_FOCUS=1: not activating the Unity window"
        return 0
    fi
    if qq_unity_pipeline_probe; then
        echo "[qq] Unity Pipeline is running (it ticks while unfocused): not activating the Unity window"
        return 0
    fi
    qq_activate_unity_window
}

# qq_ucli <stdout文件> <stderr文件> <参数...>：调一次 CLI，返回它的退出码。
# 关掉 MSYS 的路径自动转换：路径已经自己转好了，以 / 开头的命令参数（比如 filter）不能被改写。
qq_ucli() {
    local out="$1" err="$2"
    shift 2
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' UNITY_NO_BANNER=1 UNITY_NO_PAGER=1 UNITY_NO_UPDATE_CHECK=1 \
        "$QQ_UNITY_CLI_BIN" "$@" >"$out" 2>"$err"
}

# qq_ucli_cmd <stdout文件> <stderr文件> <传输层超时秒> <命令名> [-- <命令层参数...>]
# --project-path 每次都传：不传时 CLI 会自己挑一个开着的 Editor（可能是别的 worktree 的）。
# 全局选项（--timeout、--detach）放在命令名前面，命令层参数一律放在唯一的一个 -- 后面：
# 不加 -- 时与全局选项同名的参数（主要是 --timeout）会被客户端吞掉；写两个 -- 会报 INVALID_COMMAND_ARGS。
qq_ucli_cmd() {
    local out="$1" err="$2" to="$3"
    shift 3
    qq_ucli "$out" "$err" command --project-path "$(qq_unity_native_path "$PROJECT_DIR")" \
        --json --no-banner --non-interactive --timeout "$to" "$@"
}

# qq_ucli_cmd_retry <submit_once:0|1> <stdout文件> <stderr文件> <传输层超时秒> <命令名> [...]
# 返回信封分类（0 成功；10 busy、11 network、12 超时、13 弹窗、14 作业不存在、2 其它，见 qq-unity-cli.py envelope），
# QQ_UCLI_RC 是最后一次 CLI 的退出码。重试规则：
#   - busy（信封带 retryable，说明没执行）：任何命令都可以重试，最多 3 次；
#   - Network error（多半在 domain reload 中）：只有幂等命令可以重试；submit-once 的命令（run_tests、cancel_tests、
#     editor_play、build、menu）绝不重投，传 1；
#   - 超时：不重试，用 --timeout 6 的 editor_status 分诊「是这一条命令慢，还是整条执行门被占住」。
# 间隔默认 2 秒 / 5 秒，QQ_UNITY_CLI_RETRY_SEC 统一覆盖（测试里设 0）。
qq_ucli_cmd_retry() {
    local once="$1" out="$2" err="$3" to="$4"
    shift 4
    local attempt=0 rc cls delay label="" a
    # 提示里用命令名（第一个不以 - 开头的参数）：--detach 这类全局选项排在命令名前面
    for a in "$@"; do
        case "$a" in -*) ;; *) label="$a"; break ;; esac
    done
    while :; do
        rc=0
        qq_ucli_cmd "$out" "$err" "$to" "$@" || rc=$?
        QQ_UCLI_RC=$rc
        cls=0
        "$QQ_PY" "$QQ_UNITY_CLI_PY" envelope --file "$out" --rc "$rc" --stderr-file "$err" --label "$label" || cls=$?
        case "$cls" in
            0) return 0 ;;
            10) delay="${QQ_UNITY_CLI_RETRY_SEC:-2}" ;;
            11)
                [ "$once" = 1 ] && return "$cls"
                delay="${QQ_UNITY_CLI_RETRY_SEC:-5}"
                ;;
            12)
                qq_ucli_timeout_triage
                return "$cls"
                ;;
            *) return "$cls" ;;
        esac
        attempt=$((attempt + 1))
        [ "$attempt" -le 3 ] || return "$cls"
        echo "[unity-cli] retrying $label (${attempt}/3) in ${delay}s" >&2
        sleep "$delay"
    done
}

# 命令超时：分清是这一条命令慢，还是 CLI 执行门被占住（两者的处置相反，而后者从 Editor 的 GUI 上看不出来）
qq_ucli_timeout_triage() {
    local probe_out probe_err rc=0 cls=0
    probe_out="$(mktemp "${QQ_TEMP_DIR:-/tmp}/qq-ucli-probe.XXXXXX" 2>/dev/null || mktemp)" || return 0
    probe_err="$probe_out.err"
    qq_ucli_cmd "$probe_out" "$probe_err" 6 editor_status || rc=$?
    "$QQ_PY" "$QQ_UNITY_CLI_PY" envelope --file "$probe_out" --rc "$rc" --quiet || cls=$?
    rm -f "$probe_out" "$probe_err"
    if [ "$cls" -eq 0 ]; then
        echo "[unity-cli] The command timed out, but the CLI channel still answers: this one command was slow." >&2
    else
        {
            echo "[unity-cli] The command timed out and a 6s editor_status could not get in either: the Editor's CLI execution gate is occupied"
            echo "  (a test run in progress, a modal dialog, or a wedged command). The Editor GUI may still respond."
            echo "  Recover, lightest first: look for a dialog in the Unity window; exit Play mode in Unity; restart the Editor."
            echo "  Window/Pipeline/Stop Server goes through the same gate and will not get in while it is stuck."
        } >&2
    fi
}

# qq_unity_cli_compile <超时秒> [<compile_gate.py>]：用官方 CLI 的 recompile 触发编译，不激活窗口。
# 返回 0 成功、1 编译失败、2 超时 / 阻塞 / 拿不到可信裁决（编译门只在退 1 时立，退 2 只是提示）。
# 只在 qq_unity_channel 判出 unity-cli 时调。QQ_UNITY_RECOMPILE_KIND 记下 recompile 的回答（写 run record 用）。
qq_unity_cli_compile() {
    local timeout="${1:-15}" gate="${2:-}" tmp rc=0
    QQ_UNITY_RECOMPILE_KIND=""
    # QQ_TEMP_DIR 指向的目录不在时退回系统临时目录：拿不到临时目录不该变成「没拿到裁决」
    tmp="$(mktemp -d "${QQ_TEMP_DIR:-/tmp}/qq-ucli.XXXXXX" 2>/dev/null || mktemp -d)" || return 2
    _qq_unity_cli_compile_in "$tmp" "$timeout" "$gate" || rc=$?
    rm -rf "$tmp"
    return "$rc"
}

_qq_unity_cli_compile_in() {
    local tmp="$1" timeout="$2" gate="$3"
    local base="" rc t0 cls kind settled=0 busy=0

    # 0. Unity 里有一轮 PlayMode / 异步测试在跑（Temp/pipeline_test_request.json）时不触发：编译后的 domain reload 会把它打掉。
    #    看不见的一种：/qq:test 用 --detach 提交的 EditMode 作业不写这个文件。它在跑时整条 CLI 执行门都被占着，
    #    recompile 会排在门上等到客户端超时（钩子约 50 秒后退 2），作业结束、放开执行门后才真正执行——要是那时 Refresh
    #    找到了要编的东西，随后的 domain reload 会清掉只存在内存里的作业记录。要防住它得靠 qq 自己的测试锁（设计里的 P1，
    #    这次没做），所以 /qq:test 的说明里写了：官方 CLI 跑 EditMode 期间别改 .cs。
    if "$QQ_PY" "$QQ_UNITY_CLI_PY" test-in-flight --project "$PROJECT_DIR" >/dev/null 2>&1; then
        echo "[unity-cli] A PlayMode / async test run is in flight in Unity (Temp/pipeline_test_request.json); not triggering a compile —" >&2
        echo "  the domain reload would kill the running tests. Compile again after the tests finish." >&2
        echo "  If no test run is actually in progress (e.g. Unity restarted mid-run), delete that file and compile again." >&2
        return 2
    fi

    # 1. 先等在途的编译落地，再记基线。调用前就在跑的那次编译，开始时未必已经包含这次改动（它可能来自别的会话、
    #    上一次超时的钩子、或者人在 Unity 里触发的刷新）：recompile 这时也会回 compiling，收下它的裁决就是假绿。
    #    所以不像旧路径那样把基线退一格去收它，而是等它落地、拿一个稳定的基线（compile_gate.py 自己的 trigger 也这么做）。
    if [ -n "$gate" ]; then
        _qq_unity_cli_gate_seq "$gate" || return 2
        rc=0
        "$QQ_PY" "$gate" --project "$PROJECT_DIR" check >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 2 ] && [ "$QQ_UNITY_GATE_SEQ" -ge 0 ]; then
            settled=1
            echo "[unity-cli] A compile (seq ${QQ_UNITY_GATE_SEQ}) was already running in Unity; waiting for it to finish before triggering (its verdict may not include this change)"
            "$QQ_PY" "$gate" --project "$PROJECT_DIR" wait --since "$((QQ_UNITY_GATE_SEQ - 1))" --timeout "$timeout" >/dev/null 2>&1 || true
            _qq_unity_cli_gate_seq "$gate" || return 2
        fi
        # 等不到它落地也以当前 seq 为基线：之后只收 seq 更大的，那一定是这之后才开始的编译
        base="$QQ_UNITY_GATE_SEQ"
    else
        "$QQ_PY" "$QQ_UNITY_CLI_PY" recompile-snapshot --project "$PROJECT_DIR" --out "$tmp/s0.json" || return 2
        if "$QQ_PY" "$QQ_UNITY_CLI_PY" recompile-busy --snapshot "$tmp/s0.json"; then
            settled=1
            cp "$tmp/s0.json" "$tmp/s-busy.json"
            echo "[unity-cli] A compile was already running in Unity; waiting for it to finish before triggering (its verdict may not include this change)"
            "$QQ_PY" "$QQ_UNITY_CLI_PY" settle-recompile --project "$PROJECT_DIR" --timeout "$timeout" --poll 0.5 || true
            "$QQ_PY" "$QQ_UNITY_CLI_PY" recompile-snapshot --project "$PROJECT_DIR" --out "$tmp/s0.json" || return 2
            # 还没落地（编译很长，或者状态文件停在 compiling / triggered）：之后看到的 completed 分不清是不是它的
            if "$QQ_PY" "$QQ_UNITY_CLI_PY" recompile-busy --snapshot "$tmp/s0.json"; then busy=1; fi
        fi
    fi
    t0="$(date +%s)"

    # 2. 触发。不传 --focus（默认就是 false；老服务端没有这个参数，传了反而报 INVALID_COMMAND_ARGS）
    cls=0
    qq_ucli_cmd_retry 0 "$tmp/rc.json" "$tmp/rc.err" 30 recompile || cls=$?
    kind=unknown
    if [ "$cls" -eq 0 ]; then
        kind="$("$QQ_PY" "$QQ_UNITY_CLI_PY" recompile-kind --file "$tmp/rc.json" 2>/dev/null)" || kind=unknown
    fi
    case "$kind" in compiling|up_to_date) ;; *) kind=unknown ;; esac
    QQ_UNITY_RECOMPILE_KIND="$kind"
    echo "[unity-cli] recompile -> $kind"

    # 3. 裁决
    if [ -n "$gate" ]; then
        _qq_unity_cli_judge_gate "$tmp" "$timeout" "$gate" "$base" "$kind" "$settled"
    else
        _qq_unity_cli_judge_status "$tmp" "$timeout" "$t0" "$kind" "$settled" "$busy"
    fi
}

# 读 compile_gate 的 seq 放进 QQ_UNITY_GATE_SEQ（没有状态文件时是 -1）；读不出整数返回 1
_qq_unity_cli_gate_seq() {
    QQ_UNITY_GATE_SEQ="$("$QQ_PY" "$1" --project "$PROJECT_DIR" seq 2>/dev/null)" || QQ_UNITY_GATE_SEQ=""
    case "$QQ_UNITY_GATE_SEQ" in
        -1) return 0 ;;
        ''|*[!0-9]*) ;;
        *) return 0 ;;
    esac
    echo "[unity-cli] Could not read the compile_gate seq baseline" >&2
    return 1
}

# 有 Tools/compile_gate.py：裁决只认它的 seq 门（0/1/2）
_qq_unity_cli_judge_gate() {
    local tmp="$1" timeout="$2" gate="$3" base="$4" kind="$5" settled="$6" rc=0 require=""
    case "$kind" in
        compiling)
            # 基线是调用前已经落地的那一次：seq 更大的一定是这之后才开始的编译。不带 --trigger-file
            echo "[unity-cli] Judging via compile_gate (seq>${base})"
            "$QQ_PY" "$gate" --project "$PROJECT_DIR" wait --since "$base" --timeout "$timeout" || rc=$?
            ;;
        up_to_date)
            "$QQ_PY" "$gate" --project "$PROJECT_DIR" check >"$tmp/check.out" 2>&1 || rc=$?
            if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
                # 参照时间用那次编译的开始时间（startedAt）；刚等过一次在途编译时，没有开始时间就说不清它包不包含这次改动
                [ "$settled" = 1 ] && require=--require-start
                if _qq_unity_cli_unseen_changes "$tmp" --ref-gate-file "$PROJECT_DIR/Temp/compile_gate.json" ${require:+"$require"}; then
                    return 2
                fi
                cat "$tmp/check.out"
            else
                cat "$tmp/check.out"
                rc=0
                "$QQ_PY" "$gate" --project "$PROJECT_DIR" wait --since "$base" --timeout "$timeout" || rc=$?
            fi
            ;;
        *)
            # 不写 refresh_trigger、不激活窗口：CLI 通道可能正被在跑的测试占着，再去触发编译会引发 domain reload，
            # 打掉别人的作业。Auto Refresh 或排队的请求可能已经让它在编了，所以还是等一次 seq 门。
            echo "[unity-cli] recompile gave no usable answer; not writing refresh_trigger or activating the window. Waiting for a new compile_gate verdict (seq>${base})" >&2
            "$QQ_PY" "$gate" --project "$PROJECT_DIR" wait --since "$base" --timeout "$timeout" || rc=$?
            ;;
    esac
    [ "$rc" -le 2 ] || rc=2
    return "$rc"
}

# 没有 compile_gate：判据换成 Pipeline 包写的 Temp/pipeline_recompile_status.json
_qq_unity_cli_judge_status() {
    local tmp="$1" timeout="$2" t0="$3" kind="$4" settled="$5" busy="$6" rc=0 ref
    ref="$tmp/s0.json"
    case "$kind" in
        up_to_date)
            # up_to_date 会把上一次的红灯记录盖掉，只能拿调用前的快照当裁决
            "$QQ_PY" "$QQ_UNITY_CLI_PY" snapshot-verdict --snapshot "$tmp/s0.json" >"$tmp/verdict.out" 2>&1 || rc=$?
            if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
                # 参照时间：快照的 mtime 是那次编译的结束时间；刚等过一次在途编译时，改用等之前那份快照的 mtime
                # （compiling / triggered 写下的时刻，不晚于那次编译开始）——编译途中改的文件它未必编进去了
                [ "$settled" = 1 ] && ref="$tmp/s-busy.json"
                if _qq_unity_cli_unseen_changes "$tmp" --ref-snapshot "$ref"; then
                    return 2
                fi
            fi
            cat "$tmp/verdict.out"
            ;;
        *)
            if [ "$busy" = 1 ]; then
                # 调用前那次编译过了等待上限还没落地：之后的 completed 是它的还是这次的，状态文件说不清
                echo "[unity-cli] Unity was still busy with a compile that started before this call (waited ${timeout}s); no verdict for this change." >&2
                echo "  Compile again once Unity is idle." >&2
                return 2
            fi
            # recompile 先写了 triggered；调用前没有在途的编译，之后看到的 completed 只可能来自这之后才开始的编译
            if [ "$kind" != compiling ]; then
                echo "[unity-cli] recompile gave no usable answer; not writing refresh_trigger or activating the window. Waiting for a compile that finishes after the call" >&2
            fi
            "$QQ_PY" "$QQ_UNITY_CLI_PY" wait-recompile --project "$PROJECT_DIR" --timeout "$timeout" --poll 0.5 \
                --require-mtime-after "$t0" || rc=$?
            ;;
    esac
    [ "$rc" -le 2 ] || rc=2
    return "$rc"
}

# recompile 回 up_to_date，可上一次编译之后还有改过的 Unity 源文件 ⇒ Unity 没看见这次改动：
# Auto Refresh 关着时，外部改动的**已有** .cs 不会被 AssetDatabase.Refresh() 发现（新建的文件不受影响），
# 这时沿用上一次的裁决就是假绿。命中返回 0（并打印提示），没命中返回 1。
# 只查 auto-compile 钩子传来的那个文件（QQ_COMPILE_CHANGED_FILES）；没传就扫 Assets/、Packages/ 和 file: 本地包。
# 只有 newer-sources 明确答「没有」（退 1）才放行：它出错时证明不了 Unity 看见了改动。
_qq_unity_cli_unseen_changes() {
    local tmp="$1" found="" rc=0 info="" play_mode=""
    shift
    found="$("$QQ_PY" "$QQ_UNITY_CLI_PY" newer-sources --project "$PROJECT_DIR" "$@" \
        ${QQ_COMPILE_CHANGED_FILES:+"--changed=$QQ_COMPILE_CHANGED_FILES"} 2>/dev/null)" || rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -eq 0 ] || found="the check for unseen changes failed"
    {
        echo "[unity-cli] ⚠ Unity may not have picked up the change: recompile answered up_to_date, but ${found:-a source file is newer than the last compile}."
        echo "  With Auto Refresh off, Unity's Refresh does not notice external edits to existing .cs files."
        echo "  Reimport the file in Unity (right-click > Reimport, or the project's Force Reimport menu) or turn"
        echo "  Auto Refresh on, then compile again. qq does not reimport for you."
    } >&2
    # 顺便看一眼是不是在 Play：Play 期间 Unity 不编译脚本
    rc=0
    qq_ucli_cmd "$tmp/es.json" "$tmp/es.err" 10 editor_status || rc=$?
    if "$QQ_PY" "$QQ_UNITY_CLI_PY" envelope --file "$tmp/es.json" --rc "$rc" --quiet; then
        info="$("$QQ_PY" "$QQ_UNITY_CLI_PY" editor-status --file "$tmp/es.json" 2>/dev/null)" || info=""
        play_mode="$(printf '%s\n' "$info" | cut -f4)"
        if [ -n "$play_mode" ] && [ "$play_mode" != "-" ] && [ "$play_mode" != stopped ]; then
            echo "  Unity is also in Play mode (playMode=${play_mode}): it does not compile scripts while playing — exit Play mode first." >&2
        fi
    fi
    echo "  No compile verdict this time (exit 2)." >&2
    return 0
}
