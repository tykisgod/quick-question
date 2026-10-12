# Hook 系统

Claude Code hook 是在工具使用和会话事件发生时自动触发的 shell 脚本。qq 用 hook 实现自动编译、编译/审阅门控、skill 修改追踪、自动同步、会话清理和 compaction 后的恢复提示。所有 plugin 级 hook 定义在 [`hooks/hooks.json`](../../hooks/hooks.json)；少数项目本地 hook（如 `pre-push-test.sh`）通过 `.claude/settings.json` 接入。

## Hook 总览

| 触发器 | 匹配器 | 脚本 | 用途 |
|--------|--------|------|------|
| PreToolUse | `Edit\|Write` | `compile-gate-check.sh` | 编译红灯或项目从未在编辑器中打开过时，阻止编辑引擎源文件 |
| PreToolUse | `Edit\|Write` | `review-gate.sh check` | 审阅验证未完成时阻止编辑 |
| PreToolUse | `Bash`（项目本地） | `pre-push-test.sh` | 阻止 `git push` 直到 `./test.sh` 通过 |
| PostToolUse | `Write\|Edit` | `auto-compile.sh` | 编辑后通过 `qq-compile.sh`（多引擎分派器）自动编译引擎源文件 |
| PostToolUse | `Write\|Edit` | `skill-modified-track.sh` | 记录 skill 文件的修改 |
| PostToolUse | `Bash` | `review-gate.sh set` | 宣告代码/计划审阅脚本刚立起的审阅门 |
| PostToolUse | `Agent` | `review-gate.sh count` | 统计验证子 agent 的完成次数，达数后释放审阅门 |
| Stop | (全部) | `check-skill-review.sh` | skill 修改但未运行 `/qq:self-review` 时阻止会话结束 |
| Stop | (全部) | `review-gate.sh stop` | 审阅验证未完成时拦一次收尾 |
| Stop | (全部) | `auto-pipeline-stop.sh` | `/qq:execute --auto` 流水线运行中时阻止会话退出 |
| SessionEnd | (全部) | `session-cleanup.sh` | 清掉本会话的审阅门、修剪过期运行时数据 |
| SessionStart | (startup) | `auto-sync.sh` | 插件升级后将 plugin 脚本同步到目标项目 |
| SessionStart | `compact` | `execute-resume-hint.sh` | context compaction 后浮出 `/qq:execute` 进行中的进度 |
| SessionStart | `compact` | `auto-pipeline-resume-hint.sh` | context compaction 后浮出 auto-pipeline 进行中状态 |

## Hook 触发类型

- **PreToolUse** —— 在工具执行前运行。退出码 2（stderr 会回传给 Claude）或 `"decision":"block"` / `permissionDecision: deny` 响应会阻止工具运行。其他非零退出码只算「非阻断错误」：Claude Code 显示错误后照样执行工具，所以门检查必须 exit 2。
- **PostToolUse** —— 在工具完成后运行。可通过 `hookSpecificOutput` 向对话注入上下文。
- **Stop** —— 每次 agent 要结束这一轮回答时运行。可拦下这次收尾，让 agent 接着干。
- **SessionEnd** —— 会话结束时（退出、`/clear`、登出）运行一次。拦不住，用来做清理；进程被强杀时不运行。
- **SessionStart** —— 在会话开始（`startup`）或 context compaction 后（`compact`）运行。可注入起始上下文。

## 编译门（Compile Gate）

编译门在本会话最近一次编译为红时、以及项目从没在编辑器里打开过时，阻止对引擎源文件的编辑（都用 exit 2 拦截）。

**脚本：** `scripts/hooks/compile-gate-check.sh`
**触发器：** PreToolUse（`Edit|Write`）
**超时：** 5 秒

只对匹配引擎源文件模式的路径运行（通过 `qq_engine.py matches-source` 判定），执行两项检查：

1. **Virgin project 检查** —— 项目级事实，从文件系统读取。Unity 项目需要 `Library/`；Godot 项目需要 `.godot/`；Unreal 项目需要 `Intermediate/`。如果标记缺失，agent 会被告知先用编辑器打开项目并等初始导入完成。linked git worktree（`.git` 是文件）不做这项检查：这些目录都被 git 忽略，worktree 里本来就没有，不说明编辑器从没打开过。要给 worktree 补缓存，用 `qq-worktree.py seed-runtime-cache`。
2. **编译门检查** —— 按会话 id **和项目**隔离。编译定性失败后，`auto-compile.sh` 会写 `$QQ_TEMP_DIR/compile-gate-<session_id>-<项目哈希>`。「定性失败」指编译脚本退 1，且输出里有落在项目文件上的错误位置。门按项目分开，所以同一会话碰到的别的项目或 worktree，既不会被这扇门拦住，也不会被它放行。

   门立着时，以下文件仍然可以改：
   - 报错的文件，和触发编译的文件；一路红下去时名单会累积，所以之前的改动仍可撤回
   - 错误信息里点名的类型所在的文件，例如 `'Service' does not contain a definition for 'Foo'` 对应 `Service.cs`
   - 新建的文件
   - 项目外的文件

   不放行这些，就没法用 Edit 修错误。项目里其余已有的引擎源文件，`qq_compile_gate.py check` 一律拦截，直到门解除。门在三种情况下解除：下一次自动编译转绿；本会话里手动跑 `qq-compile.sh` 转绿（`--help` 不算）；1 小时后过期。

编译没给出裁决（退 2：Editor 没开、超时、拒绝自动改走 batch），或者退 1 但找不到错误位置（工具链或环境问题），都不立门，已有的门也不动。`compile_gate` 钩子关着时也不立门。这几种情况下，结果照样告诉 agent。Godot 的 `WARNING` 块不算错误位置。

1.19.4 之前，这个检查调了一个不存在的 `qq_detect_engine`，在两项检查之前就退 127；拦截又用的是 exit 1。所以 virgin 检查和编译门其实从来没拦过任何编辑。

门按会话 id 和项目隔离，并发的 Claude Code 会话永远看不到对方的编译状态。输出强制用 UTF-8，Windows 默认代码页下 ⛔ 提示也送得到模型。

## 自动编译

**脚本：** `scripts/hooks/auto-compile.sh`
**触发器：** PostToolUse（`Write|Edit`）
**超时：** 120 秒

文件被写入或编辑时，此 hook 检查文件是否为引擎源文件（由 `qq_engine.py matches-source` 对照当前引擎判定）。如果是，调用 `qq-compile.sh`，由它分派到正确的引擎路径：

- **Unity** → `unity-compile-smart.sh`，自动选官方 Unity CLI、tykit HTTP、editor trigger（osascript / PowerShell）或 batch mode。项目里有有效的 `Library/Pipeline/.unity-pipeline-port`（pid 活着、`projectPath` 是本项目）并且找得到 `unity` CLI（可以用 `QQ_UNITY_CLI` 指定位置）时，用 `unity command recompile` 触发编译：Unity 失焦或最小化时也能编，不会把 Unity 窗口拉到前台。裁决照旧：项目有 `Tools/compile_gate.py` 就认它，没有就读 `Temp/pipeline_recompile_status.json`。Unity 回 `up_to_date`、可改过的文件比上一次编译的开始时间新时（Auto Refresh 关着时，Unity 的 Refresh 看不见外部改动的已有 `.cs`），退 2（没拿到裁决），不沿用上一次的结论；`file:` 本地包里的文件、`Assets/` 下链接进来的目录里的文件也算。**所以 Auto Refresh 关着时，每次改已有的 `.cs` 都会得到退 2 和一句重新导入的提示**：在 Unity 里重新导入这个文件（或者跑项目的 Force Reimport 菜单），或者打开 Auto Refresh——qq 不会替你重新导入。新建的文件不受影响。钩子触发前就已经在跑的编译，会先等它落地，绝不拿它当这次改动的裁决。Unity 里有一轮 PlayMode / 异步测试在跑（`Temp/pipeline_test_request.json`）时不触发编译；`/qq:test` 以 detach 作业提交的 EditMode 测试它看不见，所以这个通道下跑长的 EditMode 测试期间不要改脚本。退 2 不会立编译门。
- **Godot** → `godot-compile.sh`（headless GDScript 校验）
- **Unreal** → `unreal-compile.sh`（UnrealBuildTool + editor commandlet）
- **S&box** → `sbox-compile.sh`（`dotnet build`）

编译日志走 hook 的 stderr。stdout 只放一段 JSON，其中的 `additionalContext` 把编译错误、门的状态和仍可修改的文件交给 agent。旧版把日志混进 stdout，Claude Code 认不出 JSON，agent 一直看不到。编译定性失败时，hook 写 `compile-gate-<session_id>`（见上文）；编译成功时删除门文件；没拿到裁决时门保持原样。

此 hook 受当前 qq profile 中 `auto_compile` 设置控制——禁用时立即退出。

## 审阅门（Review Gate）

统一脚本 `review-gate.sh` 协调四个子命令，共同强制在代码或计划审阅之后、编辑恢复之前完成验证。

> 早期安装的项目可能仍有遗留的 `review-gate-{check,set,count,stop}.sh` 文件；新的 hook 绑定应统一使用 `review-gate.sh <subcommand>` 形式。

### 激活门

**脚本：** `scripts/hooks/review-gate.sh set`
**触发器：** PostToolUse（`Bash`）

门由审阅脚本自己立，不从命令文本里猜。`code-review.sh`、`claude-review.sh`、`plan-review.sh`、`claude-plan-review.sh` 真跑完一次审阅时调用 `qq_review_gate_open`（`scripts/platform/detect.sh`），写 `$QQ_TEMP_DIR/review-gate-<session_id>`，三字段格式 `<unix_timestamp>:<completed>:<expected>`（时间戳、零个已完成验证、预期验证总数），并留一个只用一次的 `.announce` 标记。审阅失败、没有可审的改动、拿不到会话 id（例如 MCP 宿主）时都不立门。

`review_gate` 钩子关着时也不立门，不管是 `hooks.disable` 关的，还是 `workflow: prototype-loop`（原型 loop）连带关的。原型 loop 会把 `review_gate` 从 `enabled_hooks` 里去掉（除非 `hooks.enable` 明确点了它）：它只审一轮、由主 agent 自己核实，等验证子 agent 的门永远等不齐，「每条发现都交给子 agent 核实」的提示也不对。审阅脚本收到 `--workflow prototype-loop`（技能参数选了这个工作流时原样转过来）也不立门，不管配置写的是什么，除非 `hooks.enable` 点了 `review_gate`。见[配置参考](configuration.md)。

每条 Bash 命令完成后，此 hook 看有没有这个标记：有就消费掉，并注入上下文，告诉 agent 每条发现都要交给子 agent 核实：默认一个子 agent 把本轮的发现一起核完，条目多到一个核不过来才分几组并行。命令里只是出现脚本名（`echo`、`grep`、heredoc）不会立门——旧版按命令文本匹配 `./scripts/code-review.sh`，这些情况都会误立门，而技能实际调用的 `${CLAUDE_PLUGIN_ROOT}/bin/...` 反倒匹配不上。

### 检查门

**脚本：** `scripts/hooks/review-gate.sh check`
**触发器：** PreToolUse（`Edit|Write`）
**超时：** 5 秒

每次编辑或写入前，此 hook 检查当前会话是否存在门文件。如果门处于激活状态且验证子 agent 未全部完成（`completed < expected`），用 exit 2 拦下编辑。只拦项目里的文件：项目里任何位置的 `.cs`，和项目根下 `Docs/` 里的 `.md`（项目根取 `PROJECT_DIR`，没有时取 `git rev-parse --show-toplevel`）。先把路径换算成相对项目根的写法再比；Windows 的反斜杠路径、大写扩展名都认，相对路径按项目根解释。比项目根时只在 Windows 和 macOS 上不分大小写（卷不分大小写，盘符大小写不定）；Linux 上 `/tmp/GAME` 不在 `/tmp/game` 里。项目外的文件一律放行。1.22.0 之前拿绝对路径去套 `*.cs | */Docs/*.md`，项目外任何一级父目录叫 docs 的 `.md`、项目外的 `.cs` 也会被拦。门在 2 小时后自动过期。

门只管主 agent。子 agent 的工具调用带 `agent_id`，会话 id 却和主会话相同；要是也拦子 agent，并行子 agent 里任何一个跑完审查，都会把其余子 agent 一起锁住。何况验证子 agent 本来就只读。

### 计数验证

**脚本：** `scripts/hooks/review-gate.sh count`
**触发器：** PostToolUse（`Agent`）

每当主 agent 派出的 Agent 调用完成，此 hook 递增门文件中的已完成计数器（子 agent 自己派的不算）。当 `completed >= expected` 时，门释放编辑。hook 注入上下文确认计数。

### 验证未完成时阻止会话退出

**脚本：** `scripts/hooks/review-gate.sh stop`
**触发器：** Stop

agent 要结束这一轮时，此 hook 看本会话的门。核实没做完（`completed < expected`，或者还没派核实：`0:0`）就拦一次，并说明还差什么：等核实的子 agent 回来（丢了的重派），或者这一轮没有要核实的，走审阅技能的 Clean Up Gate 那一步。刚被拦回去之后的那次停（`stop_hook_active`）放行。Stop 不删门：门跨轮留着，照拦 `.cs` / `Docs/*.md` 的编辑，直到核实的子 agent 回齐、技能收尾清门（或 `review-gate.sh clear`），或者立门 2 小时后过期；过期的门在这里也会删掉。

判定只用 bash 内建，在任何 python 进程之前做完：Stop 钩子只有 2 秒，被砍等于放行。1.22.0 之前 `session-cleanup.sh` 也挂在同一个 Stop 组里，Claude Code 把同一组的钩子并行跑，清理通常抢在本 hook 读门之前把门删了，门活不过一轮；清理还把 count 刚写下的 `verified` 盖成 `cleared`，`/qq:go` 又推荐审查。

## Skill 修改追踪

**脚本：** `scripts/hooks/skill-modified-track.sh`
**触发器：** PostToolUse（`Write|Edit`）

当 skill 文件被写入或编辑（路径匹配 `*/.claude/commands/*.md` 或 `*/skills/*/SKILL.md`），此 hook 将文件路径追加到 `$QQ_TEMP_DIR/claude-skill-modified-marker-<session_id>`。

会话结束时，Stop hook `check-skill-review.sh` 检查标记文件。如果 skill 被修改但从未运行 `/qq:self-review`，hook 阻止终止并列出已修改的文件。运行 `/qq:self-review` 会清除标记。

## Auto-Pipeline 退出守护

**脚本：** `scripts/hooks/auto-pipeline-stop.sh`
**触发器：** Stop

`/qq:execute --auto` 在跑无人值守的流水线时（`.qq/state/auto-pipeline.json` 存在且活跃），此 hook 阻止会话在流水线中途结束。实际的断路器逻辑在 `qq-execute-checkpoint.py pipeline-block` 里，由它判定流水线是否仍在进行中。

它是提醒一次，不是强拦：刚被本 hook 拦回去之后的那次停（`stop_hook_active`）放行，agent 仍要停（在等用户、卡住了）就让它停，流水线留着 `running` 等续跑。它只拦开流水线或最近推进流水线的那个会话（`auto-pipeline.json` 里的 `session`，`pipeline-start` / `pipeline-advance` 从 `CLAUDE_CODE_SESSION_ID` 记下）：`claude-review.sh` 另起的 `claude -p`、同一目录里别的会话结束时不拦、不计数。1.21.2 之前 `stop_hook_active` 的判断拿 Python 打印的 `True` 比 `"true"`，永远不成立；同一目录里每个会话都被拦、被计数，光一次审查就可能凑满「同一步被拦 3 次」的熔断，把流水线标成 `abandoned`。

## 会话清理

**脚本：** `scripts/hooks/session-cleanup.sh`
**触发器：** SessionEnd
**超时：** 5 秒

删掉本会话（且只删本会话）的审查门文件和它的 `.announce` 标记，再通过 `qq_runtime_prune` 修剪过期的运行时数据。不写审查状态：state 记的是本会话的审查走到了哪一步，别的会话本来就不认它。会话被强杀时 SessionEnd 不运行，门留在临时目录里，到立门 2 小时后过期。

## SessionStart Hook

### Auto-Sync（startup）

**脚本：** `scripts/hooks/auto-sync.sh`
**超时：** 10 秒

会话启动时，此 hook 调用 `qq-auto-sync.py` 将最新 plugin 脚本镜像到目标项目的 `scripts/` 目录。这是插件升级如何在不要求用户重跑 `install.sh` 的情况下到达已安装项目的方式。

### 恢复提示（compact）

context compaction 之后，两个 hook 读取由长流程 skill 写入的状态文件，注入恢复提示让 agent 接着从中断处继续：

- **`execute-resume-hint.sh`** —— 读取 `.qq/state/execute-progress.json`（由 `/qq:execute` 写入），报告进行中的 phase、已完成的步骤和下一步要跑什么。
- **`auto-pipeline-resume-hint.sh`** —— 读取 `.qq/state/auto-pipeline.json`（由 `/qq:execute --auto` 写入），报告进行中的流水线阶段，让无人值守循环正确续跑。

如果对应状态文件不存在，两个 hook 都静默退出。

## Pre-Push 测试门（可选）

**脚本：** `scripts/hooks/pre-push-test.sh`

这是项目本地 hook，通过 `.claude/settings.json` 注册（不是 plugin 的 `hooks.json`），所以只有选择启用的项目会触发。通过 `install.sh --with-pre-push`（或手动）安装后，它拦截 `git push` 命令并在允许 push 之前先跑 `./test.sh`。测试失败则阻止 push。

## 会话隔离

所有门文件和标记文件都以 Claude Code 会话 id 作后缀。钩子从 stdin JSON 的 `session_id` 取，技能里的 Bash 从 `CLAUDE_CODE_SESSION_ID` 取（同一个值；子 agent 带的是主会话的 id，所以主会话和它的子 agent 共用一扇门），两者都经 `scripts/platform/detect.sh` 的 `qq_session_id`，只收文件名安全的字符。这确保并发的 Claude Code 会话互不干扰——每个会话的编译门、审阅门和 skill 标记都按自己的会话 id 隔离。共享 hook 状态会导致一个会话的红编译阻止另一个会话的编辑。

早先的版本按 `$PPID` 命名这些文件；Windows Git Bash 下 `$PPID` 恒为 1，全机所有会话共用一份门文件。拿不到会话 id 时，钩子既不建门也不查门，不退回共用文件。

`qq-project-state.py`（`/qq:go`、`qq-doctor`、MCP 的 `qq_project_state` 背后都是它）报 `review_gate_status` 也按会话分开：只读本会话的门（`CLAUDE_CODE_SESSION_ID`），门在、没过期就以门为准，压过 `.qq/state/review_gate.json`，除非本会话写的是一条比立门晚的 `verified`（按整秒比，同一秒算门新）：先有一扇没核完的重审核门，再走原型 loop 审过一轮写下 `verified`。没有门时，state 里的记录只在是本会话写的时候才算（运行记录带 `session_id`：钩子从 stdin 取了传进去，技能里的 Bash 取 `CLAUDE_CODE_SESSION_ID`）。不立门的原型 loop 就靠这条告诉 `/qq:go` 审过了（`shared/prototype-loop.md`）；两个代码审查技能在 Clean Up Gate 那一步收尾时，审查通过也写这么一条，没有要核实的一轮（count 钩子不会写 `verified`）也算。别的会话的记录和门一概不算。拿不到会话 id（MCP 宿主、在 Claude Code 外跑的 doctor）时不读门；记录是某个会话写的就不借用，报 `unknown`；不带 `session_id` 的记录（CI、eval、终端里手跑，或 1.22.0 之前写的）照认。`review-gate.sh clear` 不看 `review_gate` 开关，总是删掉本会话的门：切到原型 loop 以后，重审核留下的门照样清得掉。没设 `QQ_TEMP_DIR` 时和 `detect.sh` 找同一个目录：Windows 取 `TEMP`，其他平台取 `/tmp`。1.22.0 之前没有 state 时会扫全机所有会话的门（`.announce` 标记也当门读），有 state 时返回项目里最后一条、不管是哪个会话写的，默认目录还退回 `TMPDIR` / `"/tmp"`，在 macOS 和 Windows 上都和 shell 侧对不上。

## 实现说明

### Hook 输入解析

Hook 脚本通过 [`scripts/qq-runtime.sh`](../../scripts/qq-runtime.sh) 中共享的 `qq_hook_input` 辅助函数从 stdin 读取 tool input。该辅助函数优先用 `jq`，没有时 fallback 到 `$QQ_PY`（python3）——所以装有 python3 但没有 jq 的 Windows 机器上 hook 也能跑，不会让宿主脚本在 `set -euo pipefail` 下崩溃。

```bash
file_path="$(qq_hook_input tool_input.file_path)"
cmd="$(qq_hook_input tool_input.command)"
```

新的 hook 脚本不应直接调用 `jq`。

### 幂等性

Hook 可能对同一输入触发两次（Claude Code 在瞬时失败时会重试）。副作用（写门文件、追加标记、记录运行状态）必须是幂等的。当前大多数 hook 通过 write-then-overwrite 而非 append、或通过标记检查来守护 append 实现幂等。

### 引擎检测

关心引擎类型的 hook 调用 `qq_engine.py matches-source` 而不是硬编码 `*.cs`。这是同一份 `auto-compile.sh` 和 `compile-gate-check.sh` 在 Unity、Godot、Unreal 和 S&box 上都正确工作的方式。

只有项目根目录里的路径才算数。`matches-source` / `matches-verification` 先把路径换成绝对路径（相对路径按项目根解释），不在项目根下就答 `false`，带 `..` 跳出项目根的相对路径也一样——所以往草稿目录写个 `.cs` 既不会触发编译，也不会碰上编译门。盘符大小写、`C:/` 与 `C:\` 两种写法、8.3 短名、经由符号链接或目录联接给出的项目根、不分大小写的卷上换了大小写的写法，都按同一个位置看待；项目里链接到项目外的子目录（比如做成目录联接的 `Assets/Shared`）照样算项目里。另有两条：

- 建在项目根下面的 git worktree（比如 `<项目根>/.claude/worktrees/<名>`）是另一份检出，里面的文件算项目外。项目根下的 git 子模块和嵌套克隆照旧算项目里。
- Unity 在 `Packages/manifest.json` 里用 `file:<目录>` 引用的本地包，即使放在项目根外面也算项目里，因为 Unity 会把它编进项目。

## 相关文档

- [架构总览](../dev/architecture/overview.md)
- [跨模型审阅](cross-model-review.md) —— 审阅门如何融入 tribunal 流程
- [配置参考](configuration.md) —— 通过当前 profile 控制哪些 hook 运行
