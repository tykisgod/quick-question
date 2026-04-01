# 快速上手

qq 已经装好了，接下来怎么做？从 `/qq:go` 开始——它会读取项目状态并推荐下一步。你也可以直接跳到任何 skill：`/qq:design`、`/qq:test`、`/qq:best-practice`。控制器会自适应，不需要你按固定顺序操作。

---

## 场景一：从零构建一个功能

独立开发者。一句话需求："加个食物系统。"

```
/qq:go "add a food system"
```

qq 建议 `/qq:design`。问三个问题（参考游戏？数据格式？MVP 范围？），写出设计文档。

→ "设计完成。运行 `/qq:plan`？"——读取设计文档，探索代码库，输出 6 步实现计划，附带文件路径和接口定义。

→ "计划完成。运行 `/qq:execute`？"——创建 `IFoodSource`，实现 `HungerSystem` 和 `FoodContainer`，接入现有 `NeedSystem`。每次 `.cs` 保存自动编译。

→ "运行 `/qq:best-practice`？"——发现 `Update` 里调用了 `GetComponent`，还有一处事件没退订。已修复。

→ "运行 `/qq:test`？"——全绿。→ "运行 `/qq:commit-push`？"

或者跳过所有提示：`/qq:go --auto "add a food system"` 一路跑到底。

---

## 场景二：合并前审阅代码

团队开发者。5 个文件、400 行 C# 改动。准备审阅。

```
/qq:go
```

qq 检测到未提交的 `.cs` 改动，建议 `/qq:best-practice`。发现一个应该是 `[SerializeField] private` 的 `public` 字段，以及一处漏掉的 `CompareTag`。30 秒修完。

→ "运行 `/qq:codex-code-review`？"——diff 发送给 Codex。Review Gate 锁定编辑。子 agent 验证：1 条关键问题确认（重生时缺少 `isDead` 守卫），1 条误报驳回。修复应用，门解锁。

→ "运行 `/qq:doc-drift`？"——设计文档写的是 30% HP 触发着火，代码里是 25%。文档已更新。

→ "运行 `/qq:commit-push`？"——pre-push hook 跑测试。全绿。已推送。

---

## 场景三：理解大型代码库

新团队成员。第一天面对 20 万行 Unity 项目。

```
/qq:grandma "task system"
```

> "想象一个餐厅。每个船员是服务员，任务系统就是经理——它看着所有餐桌，判断谁离得最近、谁有空，然后分配任务。紧急的桌子插队。"

现在来技术版：

```
/qq:explain TaskSystem
```

输出：职责、核心类、数据流、生命周期钩子、设计决策。

```
/qq:deps
```

Mermaid 依赖关系图，展示所有 `.asmdef` 模块。`TaskSystem` 依赖 `NavigationSystem` 和 `NeedSystem`，不依赖 `CombatSystem`——边界清晰。

---

## 控制流程强度

两个旋钮控制 qq 施加多少仪式感：

**`work_mode`** 回答的是"这是什么类型的任务？"

| 模式 | 适用场景 | 跳过什么 |
|------|---------|---------|
| `prototype` | 灰盒、fun check | 正式文档、完整审阅 |
| `feature` | 构建可保留的系统 | 每次改动跑完整回归 |
| `fix` | bug 修复、回归修复 | 大规模重构 |
| `hardening` | 发版准备、高风险重构 | 原型快捷方式 |

**`policy_profile`** 回答的是"这个项目需要多少验证？"两者相互独立——prototype 和 hardening 可以共享同一个 policy profile，也可以不。

在 `qq.yaml`（共享默认值）或 `.qq/local.yaml`（每个 worktree 覆盖）中设置。显式指定的测试参数仍然会覆盖默认测试范围。

### 常用命令

```bash
/qq:go                                          # 我在哪？接下来该做什么？
/qq:go "add health system"                      # 从一个想法开始
python3 ./scripts/qq-project-state.py --pretty  # 查看控制器状态
./scripts/qq-doctor.sh --pretty                 # 发现 provider 和路由
```

---

## 相关文档

- [配置参考](configuration.md) — qq.yaml 详解
- [工作模式](../../README.md#work-modes) — 模式表格
- [命令](../../README.md#commands) — 完整命令列表
