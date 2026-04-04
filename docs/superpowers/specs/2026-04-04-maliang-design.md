# Maliang (马良) — Agent-Agnostic Game Dev Pipeline Orchestrator

**Date:** 2026-04-04
**Status:** Draft — pending review
**Repo:** New private repo `maliang` (not part of qq)

---

## 1. Problem Statement

Current agent-driven dev loops (including qq) put the LLM in charge of control flow. The agent reads prompts (skills), decides what to do next, and scripts/hooks are bolted on as side-channel corrections. This creates:

- **Non-determinism at critical junctures:** routing, classification, retry decisions vary per run
- **Unobservable execution:** mid-step state lives in conversation context, invisible to UI or other systems
- **No pipeline integration:** can't block on external dependencies (art assets), can't feed structured data to downstream systems
- **Agent lock-in:** switching from Claude to Codex requires rewriting all skills

Maliang inverts the control: **Python owns the loop, agents are stateless function calls.**

## 2. Design Principles

1. **Deterministic by default.** Every routing, gating, retry, and state transition decision is made by Python code. Agents only do creative work (write code, write design docs, review).
2. **Agent as function.** Each agent call receives a self-contained `TaskSpec` and returns a structured `TaskResult`. No conversation memory, no persistent sessions. Python is the team's memory.
3. **Observable everything.** Every state change emits an event. UI, logging, downstream pipelines all subscribe to the same EventBus.
4. **Pipeline-native.** External dependencies (art assets, doc reviews, human decisions) are first-class citizens with blocking/unblocking semantics, not afterthoughts.
5. **Pluggable backends.** Agent adapters (Claude, Codex, Gemini, local LLM) and engine adapters (Unity, Godot, Unreal) are swappable without changing pipeline logic.

## 3. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     UI / Voice / API                         │
│               (subscribes to events, sends commands)         │
└────────────────────────┬────────────────────────────────────┘
                         │ events up / commands down
┌────────────────────────┴────────────────────────────────────┐
│                   Pipeline Runner (Python)                    │
│                                                              │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────────┐  │
│  │ Pipeline FSM  │  │ Step Registry │  │    Event Bus     │  │
│  │ (state machine│  │ (data, not    │  │  (observable)    │  │
│  │  + scheduler) │  │  prompts)     │  │                  │  │
│  └──────┬───────┘  └───────┬───────┘  └────────┬─────────┘  │
│         │                  │                    │            │
│  ┌──────┴──────────────────┴────────────────────┴─────────┐  │
│  │                   Step Executor                         │  │
│  │  for each substep:                                      │  │
│  │    1. dependency check    (deterministic)                │  │
│  │    2. build TaskSpec      (deterministic)                │  │
│  │    3. call agent adapter  (creative)                     │  │
│  │    4. compile check       (deterministic)                │  │
│  │    5. acceptance check    (deterministic)                │  │
│  │    6. harvest decisions   (deterministic)                │  │
│  │    7. advance state       (deterministic)                │  │
│  └─────────────────────┬──────────────────────────────────┘  │
│                        │                                     │
│  ┌─────────────────────┴──────────────────────────────────┐  │
│  │              Agent Adapters (pluggable)                  │  │
│  │  ┌─────────┐ ┌───────┐ ┌────────┐ ┌────────────────┐  │  │
│  │  │ Claude  │ │ Codex │ │ Gemini │ │ Local (ollama) │  │  │
│  │  └─────────┘ └───────┘ └────────┘ └────────────────┘  │  │
│  └────────────────────────────────────────────────────────┘  │
│                        │                                     │
│  ┌─────────────────────┴──────────────────────────────────┐  │
│  │              Engine Adapters (pluggable)                 │  │
│  │  ┌──────────────┐  ┌────────┐  ┌────────┐             │  │
│  │  │ Unity(tykit) │  │ Godot  │  │ Unreal │             │  │
│  │  └──────────────┘  └────────┘  └────────┘             │  │
│  └────────────────────────────────────────────────────────┘  │
│                        │                                     │
│  ┌─────────────────────┴──────────────────────────────────┐  │
│  │              External Dep Manager                       │  │
│  │  send specs → receive assets/questions → unblock steps  │  │
│  └────────────────────────────────────────────────────────┘  │
└────────────────────────┬────────────────────────────────────┘
                         │ structured I/O
            ┌────────────┴────────────┐
            ↓                         ↓
     Doc Pipeline (upstream)    Art Pipeline (downstream)
```

## 4. Core Components

### 4.1 Pipeline FSM

The top-level state machine. Selects which pipeline to run based on work mode, then drives the macro steps (design → plan → execute → review → test → commit).

```python
class PipelineState:
    """Persisted as JSON in .maliang/state/pipeline.json"""
    pipeline_name: str                    # "feature" | "prototype" | "fix" | "hardening"
    current_phase: str                    # "design" | "plan" | "execute" | ...
    current_substep: int | None           # within execute phase
    pause_policy: PausePolicy             # "auto" | "guided" | "manual"
    steps: list[StepState]                # per-step status, result, retries
    external_deps: list[ExternalDep]      # tracked dependencies
    accumulated_decisions: list[str]      # cross-step memory
    started_at: str
    updated_at: str

class PausePolicy(str, Enum):
    AUTO = "auto"         # never pause, run to completion or failure
    GUIDED = "guided"     # pause at gates (approve design, choose approach)
    MANUAL = "manual"     # pause before every step, wait for user confirmation
```

**Pipeline definitions are data:**

```python
PIPELINES = {
    "feature": Pipeline(phases=[
        Phase("design",        agent_task="design",        post_check="design_doc_exists"),
        Phase("design_review", agent_task="review_design", post_check="review_is_solid",
              on_fail=Retry(max=3, goto="design")),
        Phase("plan",          agent_task="plan",          post_check="plan_valid_yaml"),
        Phase("plan_review",   agent_task="review_plan",   post_check="review_is_solid",
              on_fail=Retry(max=3, goto="plan")),
        Phase("execute",       executor="substep_runner",  post_check="compiles"),
        Phase("code_review",   agent_task="review_code",   post_check="no_critical",
              on_fail=Retry(max=5)),
        Phase("test",          engine_task="run_tests",    post_check="tests_pass"),
        Phase("commit",        agent_task="commit",        post_check="pushed"),
    ]),
    "prototype": Pipeline(phases=[
        Phase("execute", ...),
        Phase("commit", ...),
    ]),
    "fix": Pipeline(phases=[
        Phase("execute", ...),
        Phase("test", ...),
        Phase("commit", ...),
    ]),
    "hardening": Pipeline(phases=[
        Phase("test", ...),
        Phase("code_review", ...),
        Phase("doc_drift", ...),
        Phase("commit", ...),
    ]),
}
```

### 4.2 Step Executor (Substep Runner)

The execute phase is special: it reads a structured plan and runs each substep as an independent agent call.

```python
class StepExecutor:
    async def run_plan(self, plan: ImplementationPlan, state: PipelineState):
        for i, substep in enumerate(plan.steps):
            if state.is_substep_completed(i):
                continue  # resume support

            # 1. dependency check (deterministic)
            unmet = self.check_deps(substep, state)
            if unmet and not all(d.has_placeholder for d in unmet):
                state.mark_blocked(i, unmet)
                self.bus.emit("substep.blocked", i, unmet)
                continue

            # 2. build TaskSpec (deterministic — Python decides what agent sees)
            task = TaskSpec(
                instruction=substep.instruction,
                acceptance_criteria=substep.acceptance_criteria,
                files_to_read=substep.files_to_read,
                files_to_edit=substep.files_to_edit,
                prior_decisions=state.accumulated_decisions,
                available_assets=state.get_delivered_assets(substep),
                style_guide=self.project.style_guide,
            )

            # 3. call agent (creative)
            self.bus.emit("substep.agent_calling", i, task.instruction)
            result = await self.agent.execute(task)

            # 4. compile (deterministic)
            compile_result = await self.engine.compile()
            if not compile_result.ok:
                result = await self.try_fix_compile(task, compile_result, max_retries=2)
                if not result:
                    state.mark_failed(i, compile_result.errors)
                    self.bus.emit("substep.compile_failed", i)
                    if state.pause_policy != PausePolicy.AUTO:
                        return StepOutcome.BLOCKED
                    continue

            # 5. acceptance check (deterministic)
            checks = await self.run_acceptance(substep.acceptance_criteria)
            if not checks.all_passed:
                state.record_partial(i, checks)

            # 6. harvest decisions (deterministic)
            state.accumulated_decisions.extend(result.decisions_made)

            # 7. advance (deterministic)
            state.complete_substep(i, result)
            self.bus.emit("substep.completed", i, substep.title)
            state.save()  # persist after every substep

        # handle any still-blocked substeps
        blocked = state.get_blocked_substeps()
        if blocked:
            return StepOutcome.WAITING_ON_DEPS
        return StepOutcome.COMPLETED
```

### 4.3 TaskSpec and TaskResult

The contract between Python orchestrator and agent.

```python
@dataclass
class TaskSpec:
    """Complete input for one agent call. Agent needs nothing else."""

    # What to do
    instruction: str
    acceptance_criteria: list[str]

    # Scoped file access
    files_to_read: list[str]    # context files (read-only)
    files_to_edit: list[str]    # whitelist of editable files

    # Accumulated knowledge from prior steps
    prior_decisions: list[str]

    # Constraints
    engine: str                  # "unity" | "godot" | "unreal"
    style_guide: str             # coding conventions
    max_new_files: int = 3       # prevent agent file sprawl
    max_turns: int = 20          # hard limit on agent tool calls

    # Available assets (from art pipeline or placeholders)
    available_assets: dict[str, str]  # name → path


@dataclass
class TaskResult:
    """Structured output from one agent call."""

    files_modified: list[str]
    files_created: list[str]
    decisions_made: list[str]     # design decisions for future steps
    questions: list[str]          # uncertainties (trigger pause)
    self_assessment: str          # "complete" | "partial: <reason>"
    raw_output: str               # full agent output for logging
```

### 4.4 Agent Adapters

```python
class AgentAdapter(Protocol):
    """Agent sees a task, returns a result. No pipeline awareness."""

    async def execute(self, task: TaskSpec) -> TaskResult: ...
    async def review(self, code: str, criteria: list[str]) -> ReviewResult: ...
    async def design(self, brief: str, context: ProjectContext) -> str: ...
    async def plan(self, design_doc: str, context: ProjectContext) -> dict: ...


class ClaudeAdapter(AgentAdapter):
    """Via Claude Agent SDK (claude-agent-sdk-python)"""

    def __init__(self, model: str = "claude-sonnet-4-6"):
        self.model = model

    async def execute(self, task: TaskSpec) -> TaskResult:
        prompt = self._render_prompt(task)
        messages = []
        async for msg in claude_sdk.query(
            prompt=prompt,
            model=self.model,
            allowed_tools=["Read", "Edit", "Write", "Glob", "Grep", "Bash"],
            disallowed_tools=["Agent"],
            max_turns=task.max_turns,
            permission_mode="acceptEdits",
        ):
            if msg.type == "result":
                return self._parse_result(msg)
            elif msg.type == "tool_use":
                self.bus.emit("agent.tool_call", msg.tool, msg.input)
        raise AgentError("Agent exited without result")


class CodexAdapter(AgentAdapter):
    """Via codex exec CLI"""
    ...

class GeminiAdapter(AgentAdapter):
    """Via Gemini CLI or API"""
    ...

class OllamaAdapter(AgentAdapter):
    """Via local Ollama server"""
    ...
```

**MVP ships with:** `ClaudeAdapter` fully implemented, `CodexAdapter` as stretch goal.

### 4.5 Engine Adapters

```python
class EngineAdapter(Protocol):
    async def compile(self) -> CompileResult: ...
    async def run_tests(self, scope: str = "all") -> TestResult: ...
    async def get_project_state(self) -> ProjectState: ...


class UnityAdapter(EngineAdapter):
    """Three-tier: tykit HTTP → Editor trigger → batch mode"""

    async def compile(self) -> CompileResult:
        if self.tykit_available:
            return await self._tykit_compile()
        elif self.editor_running:
            return await self._editor_trigger_compile()
        else:
            return await self._batch_compile()

    async def run_tests(self, scope="all") -> TestResult:
        # scope: "editmode" | "playmode" | "all"
        ...

    async def get_project_state(self) -> ProjectState:
        # reads Library/, Temp/tykit.json, Editor.log
        ...
```

**MVP ships with:** `UnityAdapter` fully implemented (ported from qq's shell scripts to Python).

### 4.6 Event Bus

```python
class EventBus:
    """All state changes are events. UI, pipelines, logging all subscribe."""

    async def emit(self, event: str, **data):
        for subscriber in self._subscribers[event]:
            await subscriber(event, data)
        for subscriber in self._subscribers["*"]:  # wildcard
            await subscriber(event, data)

    def on(self, event: str, callback): ...
    def off(self, event: str, callback): ...


# Event categories:
#
# pipeline.*
#   pipeline.started          {pipeline_name, pause_policy}
#   pipeline.phase.entering   {phase_name}
#   pipeline.phase.completed  {phase_name, result}
#   pipeline.completed        {summary}
#   pipeline.blocked          {reason, blocked_deps}
#   pipeline.resumed          {unblocked_steps}
#   pipeline.failed           {phase, error}
#
# substep.*
#   substep.entering          {index, title}
#   substep.agent_calling     {index, instruction}
#   substep.completed         {index, title, files_changed}
#   substep.compile_failed    {index, errors}
#   substep.blocked           {index, unmet_deps}
#   substep.using_placeholder {index, placeholders}
#
# agent.*
#   agent.streaming           {chunk}          (real-time output for UI)
#   agent.tool_call           {tool, input}    (what agent is doing)
#   agent.completed           {duration, tokens_used}
#
# compile.*
#   compile.started           {}
#   compile.succeeded         {duration}
#   compile.failed            {errors}
#
# external.*
#   external.request_sent     {dep_id, target, spec}
#   external.delivered        {dep_id, artifact_path}
#   external.question         {dep_id, question}
#   external.answer_sent      {dep_id, answer}
#   external.rejected         {dep_id, reason}
#
# review.*
#   review.started            {scope}
#   review.finding            {severity, description}
#   review.completed          {critical_count, moderate_count}
#
# test.*
#   test.started              {scope}
#   test.passed               {count}
#   test.failed               {count, failures}
#
# decision.*
#   decision.awaiting         {prompt, options}    (needs user input)
#   decision.received         {choice}
```

### 4.7 External Dependency Manager

Handles bidirectional communication with art pipeline (and any other external systems).

```python
class ExternalDepManager:
    """Track, send, receive, block, unblock external dependencies."""

    def __init__(self, bus: EventBus, inbox: Path, outbox: Path):
        self.inbox = inbox    # .maliang/inbox/  — incoming deliveries
        self.outbox = outbox  # .maliang/outbox/ — outgoing requests
        self.deps: dict[str, ExternalDep] = {}

    async def request(self, dep: ExternalDep):
        """Send a spec to downstream pipeline."""
        self.deps[dep.id] = dep
        spec_file = self.outbox / f"{dep.id}.json"
        spec_file.write_text(json.dumps({
            "id": dep.id,
            "kind": dep.kind,
            "spec": dep.spec,
            "requested_at": now_iso(),
        }))
        self.bus.emit("external.request_sent", dep_id=dep.id, spec=dep.spec)

    async def check_inbox(self):
        """Poll inbox for deliveries, questions, rejections."""
        for f in self.inbox.glob("*.json"):
            msg = json.loads(f.read_text())
            match msg["type"]:
                case "delivery":
                    self.deps[msg["dep_id"]].status = "delivered"
                    self.deps[msg["dep_id"]].artifact = msg["artifact_path"]
                    self.bus.emit("external.delivered", dep_id=msg["dep_id"])
                case "question":
                    self.bus.emit("external.question",
                                 dep_id=msg["dep_id"], question=msg["question"])
                case "rejection":
                    self.deps[msg["dep_id"]].status = "rejected"
                    self.bus.emit("external.rejected",
                                 dep_id=msg["dep_id"], reason=msg["reason"])
            f.rename(self.inbox / "processed" / f.name)

    async def answer_question(self, dep_id: str, answer: str):
        """User answered a question from downstream."""
        reply_file = self.outbox / f"{dep_id}_reply.json"
        reply_file.write_text(json.dumps({
            "dep_id": dep_id,
            "type": "answer",
            "answer": answer,
        }))
        self.bus.emit("external.answer_sent", dep_id=dep_id, answer=answer)

    def get_unmet_for_step(self, step) -> list[ExternalDep]:
        """Which deps does this step need that haven't been delivered?"""
        return [
            self.deps[d.id]
            for d in step.art_dependencies
            if self.deps.get(d.id, {}).status != "delivered"
        ]
```

**V1 transport: file-based (inbox/outbox).** Future: WebSocket, Redis streams, or HTTP webhook — the `ExternalDepManager` is the only component that touches the transport, so swapping is trivial.

### 4.8 Plan Format

Plans must be machine-readable. Agent generates them; Python validates and executes.

```yaml
# .maliang/plans/inventory_implementation.yaml

metadata:
  feature: "inventory-system"
  design_doc: "docs/design/inventory_design.md"
  engine: unity
  generated_by: claude-sonnet-4-6
  generated_at: "2026-04-04T10:30:00Z"

steps:
  - id: 1
    title: "InventoryData ScriptableObject"
    instruction: |
      Create InventoryData ScriptableObject with slot count,
      max stack size, and item type enum.
    files_to_read:
      - "Assets/Scripts/Core/GameData.cs"
    files_to_edit:
      - "Assets/Scripts/Inventory/InventoryData.cs"
    acceptance_criteria:
      - "InventoryData inherits ScriptableObject"
      - "Contains SlotCount, MaxStackSize fields"
      - "Compiles"
    depends_on: []
    art_dependencies: []

  - id: 2
    title: "IInventorySlot interface"
    instruction: |
      Define IInventorySlot interface with Add, Remove,
      GetItem, IsFull methods.
    files_to_read:
      - "Assets/Scripts/Inventory/InventoryData.cs"
    files_to_edit:
      - "Assets/Scripts/Inventory/IInventorySlot.cs"
    acceptance_criteria:
      - "Interface defines Add, Remove, GetItem, IsFull"
      - "Compiles"
    depends_on: [1]
    art_dependencies: []

  - id: 5
    title: "UI Slot Assembly"
    instruction: |
      Assemble inventory UI grid using slot sprites.
      Implement slot highlight and selection states.
    files_to_read:
      - "Assets/Scripts/Inventory/IInventorySlot.cs"
      - "Assets/Scripts/Inventory/InventorySlot.cs"
    files_to_edit:
      - "Assets/Scripts/Inventory/UI/InventoryGrid.cs"
    acceptance_criteria:
      - "Grid correctly lays out slots"
      - "Slots respond to pointer enter/exit"
      - "Compiles"
    depends_on: [1, 2, 3]
    art_dependencies:
      - id: "art:slot_sprite"
        spec:
          format: png
          dimensions: "96x96"
          variants: ["normal", "highlighted", "disabled"]
        placeholder: "Assets/Placeholders/slot_96.png"
        blocking: false  # can proceed with placeholder
```

**Plan validation (deterministic, runs as post_check after plan phase):**

```python
class PlanValidator:
    def validate(self, plan: dict) -> ValidationResult:
        errors = []
        step_ids = {s["id"] for s in plan["steps"]}

        for step in plan["steps"]:
            # required fields
            for field in ["id", "title", "instruction",
                         "files_to_edit", "acceptance_criteria"]:
                if field not in step:
                    errors.append(f"Step {step.get('id','?')}: missing '{field}'")

            # dependency references valid
            for dep in step.get("depends_on", []):
                if dep not in step_ids:
                    errors.append(f"Step {step['id']}: depends_on {dep} not found")

            # no circular dependencies
            # (topological sort check)

            # no engine-internal files
            for f in step.get("files_to_edit", []):
                if any(p in f for p in ["Packages/", "Library/", "ProjectSettings/"]):
                    errors.append(f"Step {step['id']}: cannot edit engine file {f}")

        return ValidationResult(ok=not errors, errors=errors)
```

## 5. Pipeline Runner: Main Loop

```python
class PipelineRunner:
    def __init__(
        self,
        agent: AgentAdapter,
        engine: EngineAdapter,
        bus: EventBus,
        dep_mgr: ExternalDepManager,
        state_dir: Path,
    ):
        self.agent = agent
        self.engine = engine
        self.bus = bus
        self.dep_mgr = dep_mgr
        self.state = PipelineState.load(state_dir) or PipelineState.new()
        self.step_executor = StepExecutor(agent, engine, bus, dep_mgr)

    async def run(self):
        pipeline = PIPELINES[self.state.pipeline_name]
        self.bus.emit("pipeline.started",
                      pipeline=self.state.pipeline_name,
                      policy=self.state.pause_policy)

        for phase in pipeline.phases:
            if self.state.is_phase_completed(phase.name):
                continue  # resume support

            self.state.current_phase = phase.name
            self.bus.emit("pipeline.phase.entering", phase=phase.name)

            # pause check
            if self.should_pause(phase):
                self.bus.emit("decision.awaiting",
                              prompt=f"About to start '{phase.name}'. Proceed?",
                              options=["proceed", "skip", "abort"])
                return RunOutcome.AWAITING_DECISION

            # execute the phase
            outcome = await self.run_phase(phase)

            match outcome:
                case PhaseOutcome.COMPLETED:
                    self.state.complete_phase(phase.name)
                    self.bus.emit("pipeline.phase.completed", phase=phase.name)
                    self.state.save()

                case PhaseOutcome.RETRY(goto=target):
                    # review said "needs rework" — go back
                    self.state.rewind_to(target)
                    self.bus.emit("pipeline.phase.rewound", target=target)
                    return await self.run()  # restart from target

                case PhaseOutcome.BLOCKED:
                    self.bus.emit("pipeline.blocked", phase=phase.name)
                    return RunOutcome.BLOCKED

                case PhaseOutcome.FAILED(error=err):
                    self.bus.emit("pipeline.failed", phase=phase.name, error=err)
                    return RunOutcome.FAILED

        self.bus.emit("pipeline.completed")
        return RunOutcome.COMPLETED

    async def run_phase(self, phase: Phase) -> PhaseOutcome:
        if phase.executor == "substep_runner":
            # execute phase: read plan, run substeps
            plan = self.load_plan()
            return await self.step_executor.run_plan(plan, self.state)
        elif phase.engine_task:
            # deterministic engine task (compile, test)
            result = await getattr(self.engine, phase.engine_task)()
            if phase.post_check and not phase.post_check(result):
                return PhaseOutcome.FAILED(error=result.errors)
            return PhaseOutcome.COMPLETED
        else:
            # agent creative task (design, plan, review, commit)
            result = await self.run_agent_phase(phase)
            if phase.post_check and not phase.post_check(result, self.state):
                if phase.on_fail:
                    return PhaseOutcome.RETRY(goto=phase.on_fail.goto)
                return PhaseOutcome.FAILED(error="post_check failed")
            return PhaseOutcome.COMPLETED

    def should_pause(self, phase: Phase) -> bool:
        match self.state.pause_policy:
            case PausePolicy.AUTO:
                return False
            case PausePolicy.MANUAL:
                return True
            case PausePolicy.GUIDED:
                return phase.pause_level == PauseLevel.GATE

    # --- External event handlers (called by UI or file watcher) ---

    async def on_decision(self, choice: str):
        """User made a decision via UI."""
        match choice:
            case "proceed":
                await self.run()
            case "skip":
                self.state.skip_phase(self.state.current_phase)
                await self.run()
            case "abort":
                self.state.abort()

    async def on_external_delivery(self, dep_id: str, artifact: Path):
        """Art pipeline delivered an asset."""
        self.dep_mgr.receive(dep_id, artifact)
        # check if any blocked substeps can now proceed
        if self.state.has_blocked_substeps():
            await self.run()  # resume

    async def on_external_question(self, dep_id: str, question: str):
        """Art pipeline asked a question."""
        self.bus.emit("external.question", dep_id=dep_id, question=question)
        # UI will display, user answers, calls answer_external_question

    async def answer_external_question(self, dep_id: str, answer: str):
        """User answered via UI, forward to art pipeline."""
        await self.dep_mgr.answer_question(dep_id, answer)
```

## 6. State Persistence

All state lives in `.maliang/` within the target project directory:

```
.maliang/
├── state/
│   └── pipeline.json          # PipelineState — the single source of truth
├── plans/
│   └── <feature>_plan.yaml    # structured implementation plans
├── designs/
│   └── <feature>_design.md    # design documents
├── inbox/                     # incoming messages from external pipelines
│   └── processed/             # archived after handling
├── outbox/                    # outgoing messages to external pipelines
├── artifacts/                 # delivered art assets, received docs
├── logs/
│   └── events.jsonl           # append-only event log
└── config.yaml                # project-level maliang configuration
```

**Resume semantics:** `pipeline.json` captures enough state to resume from any point. If the process crashes mid-substep, it resumes from the last completed substep (not from the beginning).

## 7. Configuration

```yaml
# .maliang/config.yaml

agent:
  default: claude
  adapters:
    claude:
      model: claude-sonnet-4-6
      max_turns_per_call: 20
    codex:
      model: codex-mini-latest
    gemini:
      model: gemini-2.5-pro

engine:
  default: unity
  adapters:
    unity:
      project_path: "."          # relative to repo root
      tykit_enabled: true
      compile_timeout: 120
      test_timeout: 180

pipeline:
  default_pause_policy: guided   # auto | guided | manual
  default_work_mode: feature     # feature | prototype | fix | hardening

external:
  art_pipeline:
    transport: file              # file | webhook | redis
    inbox: .maliang/inbox
    outbox: .maliang/outbox
  doc_pipeline:
    watch_paths:
      - "docs/design/*.md"
      - "docs/specs/*.md"
```

## 8. CLI Interface (MVP)

```bash
# Initialize maliang in a project
maliang init --engine unity --agent claude

# Start a feature pipeline
maliang run --mode feature --input docs/design/inventory.md
maliang run --mode feature --input docs/design/inventory.md --auto

# Resume a blocked/paused pipeline
maliang resume
maliang resume --answer "dep:art:slot_sprite=/assets/delivered/slot.png"

# Check current state
maliang status
maliang status --events          # show recent event log
maliang status --deps            # show external dependency status

# Manual phase control
maliang skip design              # skip a phase
maliang retry plan               # rewind to plan phase
maliang abort                    # abort pipeline

# Deliver an external dependency manually
maliang deliver art:slot_sprite ./path/to/sprite.png

# Answer a pending question
maliang answer art:slot_sprite "No rounded corners"

# Run with different agent/engine
maliang run --agent codex --engine godot --mode prototype
```

## 9. UI Integration Surface

The UI connects via WebSocket to a lightweight HTTP server embedded in the runner:

```python
class MaliangServer:
    """HTTP + WebSocket server for UI integration."""

    # WebSocket: real-time event stream
    # GET /ws → EventBus stream (all events)

    # REST: state queries + commands
    # GET  /status              → current PipelineState
    # GET  /events?since=<ts>   → event log since timestamp
    # GET  /deps                → external dependency status
    # GET  /plan                → current plan with step statuses
    # POST /decide              → {choice: "proceed"|"skip"|"abort"}
    # POST /answer              → {dep_id, answer}
    # POST /deliver             → {dep_id, artifact_path}
    # POST /run                 → {mode, input, pause_policy}
    # POST /resume              → resume paused/blocked pipeline
    # POST /abort               → abort pipeline
```

The UI never talks to agents directly. It talks to the runner, which talks to agents.

## 10. What Maliang Is NOT

- **Not an agent framework.** It doesn't help you build agents. It orchestrates existing agents as black-box function calls.
- **Not a prompt library.** Pipeline logic is Python code, not prompts. The only prompts are the TaskSpec templates sent to agents.
- **Not an IDE plugin.** It's a standalone process. IDEs/UIs connect via HTTP/WebSocket.
- **Not qq v2.** qq is a Claude Code plugin (skills + hooks). Maliang is an independent orchestrator that happens to solve similar problems with fundamentally different architecture.

## 11. Tech Stack

| Component | Choice | Reason |
|-----------|--------|--------|
| Language | Python 3.12+ | Ecosystem, async/await, type hints |
| Async | `asyncio` (stdlib) | No extra dependency, mature |
| HTTP server | `aiohttp` or `uvicorn` + `starlette` | Lightweight, WebSocket support |
| Agent SDK | `claude-agent-sdk-python` | Official, maintained |
| CLI | `click` or `typer` | Clean CLI with subcommands |
| Config | `pydantic` | Validation, serialization, settings |
| Plan format | YAML (`ruamel.yaml`) | Human-readable + machine-parseable |
| State | JSON files | Simple, debuggable, git-friendly |
| Logging | `structlog` | Structured logging, JSON output |
| Testing | `pytest` + `pytest-asyncio` | Standard |

## 12. MVP Scope

The MVP delivers the complete feature pipeline end-to-end:

**In scope:**
- Pipeline FSM with all 4 work modes (feature, prototype, fix, hardening)
- StepExecutor with fine-grained substep execution
- ClaudeAdapter (via Agent SDK)
- UnityAdapter (ported from qq shell scripts → Python)
- EventBus with file logging
- ExternalDepManager with file-based inbox/outbox
- PlanValidator
- CLI (`maliang init`, `run`, `status`, `resume`, `deliver`, `answer`, `abort`)
- HTTP/WebSocket server for UI integration
- PipelineState persistence and resume
- `auto` / `guided` / `manual` pause policies

**Out of scope for MVP (future):**
- CodexAdapter, GeminiAdapter, OllamaAdapter (adapter interface ships, implementations later)
- GodotAdapter, UnrealAdapter (interface ships, implementations later)
- Redis/webhook transport for external deps
- Voice input processing (UI responsibility)
- Multi-project orchestration (one pipeline per project for now)
- Design generation from scratch without upstream input (MVP assumes at least one markdown doc arrives from upstream doc pipeline)

## 13. Directory Structure (Repo)

```
maliang/
├── README.md
├── pyproject.toml
├── src/
│   └── maliang/
│       ├── __init__.py
│       ├── cli.py                    # CLI entry point
│       ├── server.py                 # HTTP + WebSocket server
│       ├── core/
│       │   ├── __init__.py
│       │   ├── runner.py             # PipelineRunner
│       │   ├── state.py              # PipelineState, StepState
│       │   ├── executor.py           # StepExecutor (substep loop)
│       │   ├── pipeline.py           # Pipeline, Phase, Step definitions
│       │   ├── events.py             # EventBus
│       │   ├── task.py               # TaskSpec, TaskResult
│       │   └── validator.py          # PlanValidator
│       ├── agents/
│       │   ├── __init__.py
│       │   ├── base.py               # AgentAdapter protocol
│       │   ├── claude.py             # ClaudeAdapter
│       │   ├── codex.py              # CodexAdapter (stub)
│       │   └── prompts/
│       │       ├── design.py         # prompt templates for design tasks
│       │       ├── plan.py           # prompt templates for planning
│       │       ├── implement.py      # prompt templates for implementation
│       │       ├── review.py         # prompt templates for code review
│       │       └── commit.py         # prompt templates for commit
│       ├── engines/
│       │   ├── __init__.py
│       │   ├── base.py               # EngineAdapter protocol
│       │   └── unity.py              # UnityAdapter
│       ├── external/
│       │   ├── __init__.py
│       │   ├── deps.py               # ExternalDepManager
│       │   └── transport.py          # FileTransport (MVP), future: WebhookTransport
│       └── config.py                 # Pydantic settings / config loading
├── tests/
│   ├── test_runner.py
│   ├── test_executor.py
│   ├── test_validator.py
│   ├── test_state.py
│   ├── test_events.py
│   └── test_agents/
│       └── test_claude.py
└── docs/
    └── architecture.md
```
