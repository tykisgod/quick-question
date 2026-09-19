---
name: pipeline-needs-visibility
description: User wants real-time visibility into pipeline progress, not black-box background execution
type: feedback
---

Pipeline 跑的时候不能是黑盒——用户需要看到实时产物和进展。

**Why:** 用户发起 maliang run 后等了 25+ 分钟看不到任何产出，只能靠手动轮询 JSON 状态文件。这让人焦虑且无法判断 agent 是在认真工作还是卡住了。

**How to apply:** 
- Pipeline 执行应该有实时输出（不是后台静默跑）
- 每个阶段完成时应该打印产物摘要（设计文档多少字、plan 多少步、代码多少行）
- Agent 的 streaming output 应该透传给用户看到
- 考虑前台交互模式而非纯后台模式
