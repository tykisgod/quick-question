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
# 探测手段一条都没改（还是 tykit /ping + qq_is_unity_running），改的只是"探不到时怎么办"。
is_editor_open_for_project() {
    # 正向判据一：Unity 官方 Pipeline 的描述文件 + 端口有人应答。
    #
    # 这个判据**天然按项目限定**：描述文件在 <项目>/Library/ 下，而且自带 projectPath，
    # 两者对上才算数（防陈旧描述文件 + 端口被别的进程占用这对组合假阳性）。
    #
    # 判「有人应答」而不是「应答成功」：官方 server 对所有路径都要 Bearer 鉴权，
    # 不带 token 一律 401。**401 恰恰是最好的存活证据** —— 它是一个具体的 HTTP 回答，
    # 只有真的有个 pipeline server 在那个端口上才给得出来；连接被拒 / 超时才是「没人在」。
    # 顺带好处：本判据全程不碰 evalToken（那是任意主线程 C# 执行权限，不该进任何脚本的变量）。
    #
    # 这里曾经探的是 tykit 的 Temp/tykit.json + /ping。tykit 已换成官方 CLI，
    # 那条路会随包一起消失；留着不换的话本函数就只剩会退 2 的负向判据，
    # qq 的 unity 命令在本机永久硬失败。
    local pipe_desc="$PROJECT_DIR/Library/Pipeline/.unity-pipeline-port"
    if [ -f "$pipe_desc" ]; then
        local py_cmd="python3"
        python3 --version >/dev/null 2>&1 || py_cmd="python"
        local port
        # 只打印 port；projectPath 对不上就打印空串。**不要打印整个描述文件**。
        port=$($py_cmd -c "
import json,os,sys
try:
    d=json.load(open(r'$pipe_desc'))
except Exception:
    sys.exit(0)
a=os.path.normcase(os.path.abspath(d.get('projectPath','')))
b=os.path.normcase(os.path.abspath(r'$PROJECT_DIR'))
print(d.get('port','') if a==b else '')
" 2>/dev/null)
        if [ -n "$port" ]; then
            # -o /dev/null -w %{http_code}：连不上时 curl 输出 000，有人应答就是 401/200/...
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 \
                        "http://127.0.0.1:$port/" 2>/dev/null)
            if [ -n "$code" ] && [ "$code" != "000" ]; then
                return 0
            fi
        fi
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
