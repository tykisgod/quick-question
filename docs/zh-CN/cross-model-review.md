# 跨模型审阅（Codex Tribunal）

单模型代码审阅有盲区。模型审阅自己的输出时，往往和写代码时共享相同的假设。跨模型审阅通过让 Codex 独立审阅 diff、Claude 对照源码验证每条发现来解决这个问题。两个模型各自捕获对方遗漏的问题，比任何单一模型都能产生更高置信度的结果。

## Tribunal 流程

跨模型审阅（`/qq:codex-code-review`）以最多 5 轮的自动循环运行：

1. Claude 通过 `code-review.sh` 将 diff 发送给 Codex CLI 审阅
2. Codex 返回按严重程度分类的发现（Critical、Moderate、Suggestion）
3. 审阅门激活——Edit 和 Write 操作被阻止
4. Claude 派发并行子 agent，对照实际源码验证每条发现
5. 每个子 agent 执行过度设计检查：提议的修复是否与问题成比例？
6. 确认的关键问题被修复；过度设计的建议获得更简单的替代方案
7. 至少一个验证子 agent 完成后门解锁
8. 循环重复，直到没有关键问题或达到 5 轮上限

```mermaid
flowchart TD
    A["Codex 审阅 diff"] --> B["Claude 验证每条发现"]
    B --> C{"确认？"}
    C -->|否| D["丢弃"]
    C -->|是| E{"过度设计？"}
    E -->|是| F["更简单的修复"]
    E -->|否| G["应用修复"]
    D --> H{"还有问题？"}
    F --> H
    G --> H
    H -->|是| A
    H -->|否| I["完成"]
```

## 审阅门机制

审阅门是一个机械约束，在发现未经验证时阻止代码编辑。

- **门文件：** `$QQ_TEMP_DIR/claude-codex-review-gate-$PPID`
- **激活：** PostToolUse hook 在 `code-review.sh` 运行后设置门
- **效果：** PreToolUse hook 阻止所有对 `.cs` 和 `Docs/*.md` 文件的 Edit 和 Write 操作
- **释放：** 至少一个验证子 agent 完成后门解锁（由 PostToolUse Agent hook 追踪）
- **隔离：** 每个会话用 `$PPID` 划定门文件范围，并发会话互不干扰

审阅循环结束时门自动清理。

## 优先级分类

所有审阅命令——无论跨模型还是 Claude 单模型——都将发现分为三个层级：

| 优先级 | 范围 | 处理方式 |
|--------|------|---------|
| P0 | 架构变更、反模式、生命周期问题 | 必须审阅 |
| P1 | 业务逻辑、性能、错误处理 | 值得审阅 |
| P2 | Getter/Setter、日志、配置微调 | 快速扫一眼 |

只有 P0（Critical）发现触发自动修复和额外审阅轮次。P1 发现酌情修复。P2 发现报告但通常不处理。

## Claude 单模型替代方案

`/qq:claude-code-review` 提供相同的审阅循环，但不需要 Codex CLI。它不把 diff 发给外部模型，而是派发一个 Claude 子 agent（Opus）执行初始审阅。验证步骤完全相同：并行子 agent 对照源码验证每条发现，包含相同的过度设计检查。

Claude 单模型方案同样使用审阅门在验证期间阻止编辑。循环结构、轮数限制和终止条件都一样。

## 计划审阅

跨模型模式不仅限于代码。`/qq:codex-plan-review` 和 `/qq:claude-plan-review` 对设计文档和实现计划（而非代码 diff）应用相同的审阅-验证-修复循环。这能在问题进入实现之前就捕获架构层面的问题。

## 前置条件

- **跨模型审阅**（`/qq:codex-code-review`、`/qq:codex-plan-review`）：需要 Codex CLI（`npm install -g @openai/codex`）
- **Claude 单模型审阅**（`/qq:claude-code-review`、`/qq:claude-plan-review`）：无额外依赖

## 相关文档

- [Hook 系统](hooks.md) — 审阅门 hook（PreToolUse、PostToolUse、Stop）
- [架构总览](../dev/architecture/overview.md) — 审阅在插件层级中的位置
- [配置参考](configuration.md) — `policy_profile` 控制审阅强度
