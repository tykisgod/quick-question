# Maliang Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Maliang — a Python-driven, agent-agnostic game dev pipeline orchestrator that treats LLMs as stateless function calls, with fine-grained substep execution, external dependency management, and full observability via EventBus.

**Architecture:** Python 3.12+ asyncio application. Pipeline FSM drives macro phases (design → plan → execute → review → test → commit). StepExecutor drives substeps within execute phase. Agent and engine adapters are pluggable Protocol classes. All state persisted to JSON. EventBus provides observability. CLI via typer, HTTP/WS server via starlette/uvicorn.

**Tech Stack:** Python 3.12+, asyncio, pydantic, typer, starlette, uvicorn, ruamel.yaml, structlog, claude-agent-sdk-python, pytest, pytest-asyncio

**Spec:** `docs/superpowers/specs/2026-04-04-maliang-design.md`

---

## File Map

```
maliang/                         # new private repo
├── pyproject.toml               # Task 1
├── src/
│   └── maliang/
│       ├── __init__.py          # Task 1 (version only)
│       ├── core/
│       │   ├── __init__.py      # Task 1
│       │   ├── models.py        # Task 2 (all pydantic models)
│       │   ├── events.py        # Task 3 (EventBus)
│       │   ├── pipeline.py      # Task 4 (Pipeline, Phase, PIPELINES)
│       │   ├── validator.py     # Task 5 (PlanValidator)
│       │   ├── state.py         # Task 6 (PipelineState load/save)
│       │   ├── executor.py      # Task 7 (StepExecutor)
│       │   └── runner.py        # Task 8 (PipelineRunner)
│       ├── agents/
│       │   ├── __init__.py      # Task 9
│       │   ├── base.py          # Task 9 (AgentAdapter protocol)
│       │   ├── claude.py        # Task 10 (ClaudeAdapter)
│       │   └── prompts.py       # Task 10 (prompt templates)
│       ├── engines/
│       │   ├── __init__.py      # Task 11
│       │   ├── base.py          # Task 11 (EngineAdapter protocol)
│       │   └── unity.py         # Task 12 (UnityAdapter)
│       ├── external/
│       │   ├── __init__.py      # Task 13
│       │   └── deps.py          # Task 13 (ExternalDepManager)
│       ├── config.py            # Task 14 (Pydantic settings)
│       ├── cli.py               # Task 15 (typer CLI)
│       └── server.py            # Task 16 (HTTP + WS server)
├── tests/
│   ├── conftest.py              # Task 2
│   ├── test_models.py           # Task 2
│   ├── test_events.py           # Task 3
│   ├── test_pipeline.py         # Task 4
│   ├── test_validator.py        # Task 5
│   ├── test_state.py            # Task 6
│   ├── test_executor.py         # Task 7
│   ├── test_runner.py           # Task 8
│   ├── test_agents.py           # Task 9-10
│   ├── test_engine_base.py      # Task 11
│   ├── test_unity.py            # Task 12
│   ├── test_deps.py             # Task 13
│   ├── test_config.py           # Task 14
│   ├── test_cli.py              # Task 15
│   └── test_server.py           # Task 16
└── README.md                    # Task 17
```

---

## Task 1: Project Scaffold + pyproject.toml

**Files:**
- Create: `pyproject.toml`
- Create: `src/maliang/__init__.py`
- Create: `src/maliang/core/__init__.py`
- Create: `tests/conftest.py`

- [ ] **Step 1: Create the repo and pyproject.toml**

```toml
[project]
name = "maliang"
version = "0.1.0"
description = "Agent-agnostic game dev pipeline orchestrator"
requires-python = ">=3.12"
dependencies = [
    "pydantic>=2.7",
    "typer>=0.12",
    "starlette>=0.37",
    "uvicorn[standard]>=0.30",
    "ruamel.yaml>=0.18",
    "structlog>=24.1",
    "claude-agent-sdk>=0.1",
    "aiofiles>=24.1",
    "websockets>=12.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-asyncio>=0.23",
    "pytest-cov>=5.0",
    "ruff>=0.4",
]

[project.scripts]
maliang = "maliang.cli:app"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/maliang"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
pythonpath = ["src"]

[tool.ruff]
target-version = "py312"
line-length = 100
```

- [ ] **Step 2: Create __init__.py files**

`src/maliang/__init__.py`:
```python
"""Maliang — Agent-agnostic game dev pipeline orchestrator."""
__version__ = "0.1.0"
```

`src/maliang/core/__init__.py`:
```python
"""Core pipeline engine."""
```

- [ ] **Step 3: Create test conftest**

`tests/conftest.py`:
```python
"""Shared test fixtures for Maliang."""
from pathlib import Path
import pytest


@pytest.fixture
def tmp_state_dir(tmp_path: Path) -> Path:
    """Create a temporary .maliang directory structure."""
    state_dir = tmp_path / ".maliang"
    (state_dir / "state").mkdir(parents=True)
    (state_dir / "plans").mkdir()
    (state_dir / "designs").mkdir()
    (state_dir / "inbox" / "processed").mkdir(parents=True)
    (state_dir / "outbox").mkdir()
    (state_dir / "artifacts").mkdir()
    (state_dir / "logs").mkdir()
    return state_dir
```

- [ ] **Step 4: Verify scaffold**

Run: `cd maliang && pip install -e ".[dev]" && python -c "import maliang; print(maliang.__version__)"`
Expected: `0.1.0`

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: project scaffold with pyproject.toml and test fixtures"
```

---

## Task 2: Core Data Models (Pydantic)

**Files:**
- Create: `src/maliang/core/models.py`
- Create: `tests/test_models.py`

- [ ] **Step 1: Write failing tests for all models**

`tests/test_models.py`:
```python
"""Tests for core data models."""
import pytest
from maliang.core.models import (
    PausePolicy,
    PauseLevel,
    StepOutcome,
    PhaseOutcome,
    RunOutcome,
    TaskSpec,
    TaskResult,
    ExternalDep,
    StepState,
    CompileResult,
    TestResult,
    ReviewResult,
    ValidationResult,
)


class TestPausePolicy:
    def test_enum_values(self):
        assert PausePolicy.AUTO == "auto"
        assert PausePolicy.GUIDED == "guided"
        assert PausePolicy.MANUAL == "manual"


class TestTaskSpec:
    def test_create_minimal(self):
        spec = TaskSpec(
            instruction="Implement X",
            acceptance_criteria=["compiles"],
            files_to_read=["a.cs"],
            files_to_edit=["b.cs"],
            prior_decisions=[],
            engine="unity",
            style_guide="",
            available_assets={},
        )
        assert spec.max_new_files == 3
        assert spec.max_turns == 20

    def test_default_values(self):
        spec = TaskSpec(
            instruction="x",
            acceptance_criteria=[],
            files_to_read=[],
            files_to_edit=[],
            prior_decisions=[],
            engine="unity",
            style_guide="",
            available_assets={},
        )
        assert spec.max_new_files == 3
        assert spec.max_turns == 20


class TestTaskResult:
    def test_create(self):
        result = TaskResult(
            files_modified=["a.cs"],
            files_created=[],
            decisions_made=["used interface"],
            questions=[],
            self_assessment="complete",
            raw_output="...",
        )
        assert result.self_assessment == "complete"


class TestExternalDep:
    def test_create_with_placeholder(self):
        dep = ExternalDep(
            id="art:sprite",
            kind="art_asset",
            spec={"format": "png"},
            status="pending",
            placeholder="placeholder.png",
            blocking=False,
        )
        assert dep.placeholder == "placeholder.png"
        assert not dep.blocking

    def test_create_blocking_no_placeholder(self):
        dep = ExternalDep(
            id="art:vfx",
            kind="art_asset",
            spec={},
            status="pending",
        )
        assert dep.placeholder is None
        assert dep.blocking is True  # default


class TestStepState:
    def test_create_pending(self):
        s = StepState(id=1, status="pending")
        assert s.status == "pending"
        assert s.result is None


class TestCompileResult:
    def test_success(self):
        r = CompileResult(ok=True, errors=[], duration=1.5)
        assert r.ok

    def test_failure(self):
        r = CompileResult(ok=False, errors=["CS0001"], duration=2.0)
        assert not r.ok
        assert "CS0001" in r.errors


class TestValidationResult:
    def test_ok(self):
        v = ValidationResult(ok=True, errors=[])
        assert v.ok

    def test_with_errors(self):
        v = ValidationResult(ok=False, errors=["missing field"])
        assert not v.ok
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_models.py -v`
Expected: FAIL (cannot import)

- [ ] **Step 3: Implement all models**

`src/maliang/core/models.py`:
```python
"""Core data models for Maliang pipeline."""
from __future__ import annotations

from enum import Enum
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field


# --- Enums ---

class PausePolicy(str, Enum):
    AUTO = "auto"
    GUIDED = "guided"
    MANUAL = "manual"


class PauseLevel(str, Enum):
    ALWAYS = "always"
    GATE = "gate"
    NEVER = "never"


class StepOutcome(str, Enum):
    COMPLETED = "completed"
    BLOCKED = "blocked"
    WAITING_ON_DEPS = "waiting_on_deps"


class RunOutcome(str, Enum):
    COMPLETED = "completed"
    AWAITING_DECISION = "awaiting_decision"
    BLOCKED = "blocked"
    FAILED = "failed"


# PhaseOutcome needs to carry data, so use tagged classes instead of enum
class PhaseOutcome:
    class COMPLETED:
        pass

    class RETRY:
        def __init__(self, goto: str):
            self.goto = goto

    class BLOCKED:
        pass

    class FAILED:
        def __init__(self, error: str):
            self.error = error


# --- Agent contract ---

class TaskSpec(BaseModel):
    """Complete input for one agent call."""
    instruction: str
    acceptance_criteria: list[str]
    files_to_read: list[str]
    files_to_edit: list[str]
    prior_decisions: list[str]
    engine: str
    style_guide: str
    available_assets: dict[str, str] = Field(default_factory=dict)
    max_new_files: int = 3
    max_turns: int = 20


class TaskResult(BaseModel):
    """Structured output from one agent call."""
    files_modified: list[str] = Field(default_factory=list)
    files_created: list[str] = Field(default_factory=list)
    decisions_made: list[str] = Field(default_factory=list)
    questions: list[str] = Field(default_factory=list)
    self_assessment: str = "complete"
    raw_output: str = ""


# --- External dependencies ---

class ExternalDep(BaseModel):
    """An external dependency (art asset, doc review, etc.)."""
    id: str
    kind: str = "art_asset"
    spec: dict[str, Any] = Field(default_factory=dict)
    status: str = "pending"  # pending | delivered | rejected
    placeholder: str | None = None
    blocking: bool = True
    artifact: str | None = None
    conversation: list[dict[str, str]] = Field(default_factory=list)


# --- State ---

class StepState(BaseModel):
    """Per-substep state within the execute phase."""
    id: int
    status: str = "pending"  # pending | running | completed | blocked | failed | partial
    result: TaskResult | None = None
    failure_reason: str | None = None
    retries: int = 0


# --- Engine results ---

class CompileResult(BaseModel):
    ok: bool
    errors: list[str] = Field(default_factory=list)
    duration: float = 0.0


class TestResult(BaseModel):
    ok: bool
    passed: int = 0
    failed: int = 0
    failures: list[str] = Field(default_factory=list)
    duration: float = 0.0


class ReviewResult(BaseModel):
    ok: bool
    critical_count: int = 0
    moderate_count: int = 0
    findings: list[dict[str, str]] = Field(default_factory=list)


class ValidationResult(BaseModel):
    ok: bool
    errors: list[str] = Field(default_factory=list)
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_models.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/core/models.py tests/test_models.py
git commit -m "feat: core data models (pydantic) — TaskSpec, TaskResult, ExternalDep, state types"
```

---

## Task 3: EventBus

**Files:**
- Create: `src/maliang/core/events.py`
- Create: `tests/test_events.py`

- [ ] **Step 1: Write failing tests**

`tests/test_events.py`:
```python
"""Tests for EventBus."""
import asyncio
import pytest
from maliang.core.events import EventBus


class TestEventBus:
    def test_sync_emit_schedules_callback(self):
        """emit() is sync, fire-and-forget via create_task."""
        bus = EventBus()
        received = []

        async def handler(event, data):
            received.append((event, data))

        bus.on("test.event", handler)

        async def run():
            bus.emit("test.event", key="value")
            await asyncio.sleep(0.01)  # let task run
            assert len(received) == 1
            assert received[0] == ("test.event", {"key": "value"})

        asyncio.run(run())

    def test_wildcard_subscriber(self):
        bus = EventBus()
        received = []

        async def handler(event, data):
            received.append(event)

        bus.on("*", handler)

        async def run():
            bus.emit("a.b")
            bus.emit("c.d")
            await asyncio.sleep(0.01)
            assert received == ["a.b", "c.d"]

        asyncio.run(run())

    def test_off_removes_subscriber(self):
        bus = EventBus()
        received = []

        async def handler(event, data):
            received.append(event)

        bus.on("x", handler)
        bus.off("x", handler)

        async def run():
            bus.emit("x")
            await asyncio.sleep(0.01)
            assert received == []

        asyncio.run(run())

    def test_no_subscribers_no_error(self):
        bus = EventBus()
        bus.emit("no.listeners")  # should not raise


class TestEventLog:
    async def test_file_logger(self, tmp_path):
        """EventBus can log to JSONL file."""
        bus = EventBus()
        log_path = tmp_path / "events.jsonl"
        bus.enable_file_log(log_path)
        bus.emit("test.logged", foo="bar")
        await asyncio.sleep(0.05)
        lines = log_path.read_text().strip().split("\n")
        assert len(lines) == 1
        import json
        entry = json.loads(lines[0])
        assert entry["event"] == "test.logged"
        assert entry["data"]["foo"] == "bar"
        assert "timestamp" in entry
```

- [ ] **Step 2: Run to verify they fail**

Run: `pytest tests/test_events.py -v`
Expected: FAIL

- [ ] **Step 3: Implement EventBus**

`src/maliang/core/events.py`:
```python
"""EventBus — synchronous emit, async subscribers, file logging."""
from __future__ import annotations

import asyncio
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Coroutine


EventCallback = Callable[[str, dict[str, Any]], Coroutine]


class EventBus:
    """All state changes are events. emit() is sync fire-and-forget."""

    def __init__(self) -> None:
        self._subscribers: dict[str, list[EventCallback]] = defaultdict(list)
        self._log_path: Path | None = None

    def on(self, event: str, callback: EventCallback) -> None:
        self._subscribers[event].append(callback)

    def off(self, event: str, callback: EventCallback) -> None:
        subs = self._subscribers.get(event, [])
        if callback in subs:
            subs.remove(callback)

    def emit(self, event: str, **data: Any) -> None:
        """Synchronous emit. Schedules async callbacks via create_task."""
        for cb in self._subscribers.get(event, []):
            try:
                asyncio.get_running_loop()
                asyncio.create_task(cb(event, data))
            except RuntimeError:
                pass  # no running loop — skip (e.g., in shutdown)
        for cb in self._subscribers.get("*", []):
            try:
                asyncio.get_running_loop()
                asyncio.create_task(cb(event, data))
            except RuntimeError:
                pass
        if self._log_path is not None:
            self._write_log(event, data)

    def enable_file_log(self, path: Path) -> None:
        self._log_path = path

    def _write_log(self, event: str, data: dict[str, Any]) -> None:
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "event": event,
            "data": data,
        }
        with open(self._log_path, "a") as f:
            f.write(json.dumps(entry, default=str) + "\n")
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_events.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/core/events.py tests/test_events.py
git commit -m "feat: EventBus with sync emit, async subscribers, JSONL file logging"
```

---

## Task 4: Pipeline Definitions

**Files:**
- Create: `src/maliang/core/pipeline.py`
- Create: `tests/test_pipeline.py`

- [ ] **Step 1: Write failing tests**

`tests/test_pipeline.py`:
```python
"""Tests for Pipeline definitions."""
from maliang.core.pipeline import (
    Phase,
    Retry,
    Pipeline,
    PIPELINES,
)
from maliang.core.models import PauseLevel


class TestPhase:
    def test_create_agent_phase(self):
        p = Phase(name="design", agent_task="design", post_check="design_doc_exists")
        assert p.name == "design"
        assert p.executor is None

    def test_create_with_retry(self):
        p = Phase(
            name="review",
            agent_task="review_design",
            post_check="review_is_solid",
            on_fail=Retry(max=3, goto="design"),
        )
        assert p.on_fail.max == 3
        assert p.on_fail.goto == "design"

    def test_create_engine_phase(self):
        p = Phase(name="test", engine_task="run_tests", post_check="tests_pass")
        assert p.engine_task == "run_tests"

    def test_create_executor_phase(self):
        p = Phase(name="execute", executor="substep_runner", post_check="compiles")
        assert p.executor == "substep_runner"


class TestPipelines:
    def test_feature_pipeline_exists(self):
        assert "feature" in PIPELINES
        feature = PIPELINES["feature"]
        phase_names = [p.name for p in feature.phases]
        assert "design" in phase_names
        assert "execute" in phase_names
        assert "commit" in phase_names

    def test_prototype_pipeline_minimal(self):
        proto = PIPELINES["prototype"]
        phase_names = [p.name for p in proto.phases]
        assert "execute" in phase_names
        assert "commit" in phase_names
        assert "design" not in phase_names

    def test_fix_pipeline(self):
        fix = PIPELINES["fix"]
        phase_names = [p.name for p in fix.phases]
        assert "execute" in phase_names
        assert "test" in phase_names

    def test_hardening_pipeline(self):
        hard = PIPELINES["hardening"]
        phase_names = [p.name for p in hard.phases]
        assert "test" in phase_names
        assert "code_review" in phase_names

    def test_feature_review_has_goto(self):
        """code_review must have goto='execute' for rework loop."""
        feature = PIPELINES["feature"]
        code_review = next(p for p in feature.phases if p.name == "code_review")
        assert code_review.on_fail is not None
        assert code_review.on_fail.goto == "execute"
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_pipeline.py -v`
Expected: FAIL

- [ ] **Step 3: Implement pipeline definitions**

`src/maliang/core/pipeline.py`:
```python
"""Pipeline and Phase definitions — data, not prompts."""
from __future__ import annotations

from dataclasses import dataclass, field

from maliang.core.models import PauseLevel


@dataclass
class Retry:
    max: int
    goto: str | None = None


@dataclass
class Phase:
    name: str
    agent_task: str | None = None
    engine_task: str | None = None
    executor: str | None = None
    post_check: str | None = None
    on_fail: Retry | None = None
    pause_level: PauseLevel = PauseLevel.NEVER


@dataclass
class Pipeline:
    phases: list[Phase]


PIPELINES: dict[str, Pipeline] = {
    "feature": Pipeline(phases=[
        Phase("design", agent_task="design", post_check="design_doc_exists",
              pause_level=PauseLevel.GATE),
        Phase("design_review", agent_task="review_design", post_check="review_is_solid",
              on_fail=Retry(max=3, goto="design")),
        Phase("plan", agent_task="plan", post_check="plan_valid_yaml",
              pause_level=PauseLevel.GATE),
        Phase("plan_review", agent_task="review_plan", post_check="review_is_solid",
              on_fail=Retry(max=3, goto="plan")),
        Phase("execute", executor="substep_runner", post_check="compiles"),
        Phase("code_review", agent_task="review_code", post_check="no_critical",
              on_fail=Retry(max=5, goto="execute")),
        Phase("test", engine_task="run_tests", post_check="tests_pass"),
        Phase("commit", agent_task="commit", post_check="pushed"),
    ]),
    "prototype": Pipeline(phases=[
        Phase("execute", executor="substep_runner", post_check="compiles"),
        Phase("commit", agent_task="commit", post_check="pushed"),
    ]),
    "fix": Pipeline(phases=[
        Phase("execute", executor="substep_runner", post_check="compiles"),
        Phase("test", engine_task="run_tests", post_check="tests_pass"),
        Phase("commit", agent_task="commit", post_check="pushed"),
    ]),
    "hardening": Pipeline(phases=[
        Phase("test", engine_task="run_tests", post_check="tests_pass"),
        Phase("code_review", agent_task="review_code", post_check="no_critical",
              on_fail=Retry(max=5, goto="test")),
        Phase("doc_drift", agent_task="doc_drift", post_check="no_drift"),
        Phase("commit", agent_task="commit", post_check="pushed"),
    ]),
}
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_pipeline.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/core/pipeline.py tests/test_pipeline.py
git commit -m "feat: pipeline definitions — feature, prototype, fix, hardening"
```

---

## Task 5: Plan Validator

**Files:**
- Create: `src/maliang/core/validator.py`
- Create: `tests/test_validator.py`

- [ ] **Step 1: Write failing tests**

`tests/test_validator.py`:
```python
"""Tests for PlanValidator."""
import pytest
from maliang.core.validator import PlanValidator


@pytest.fixture
def validator():
    return PlanValidator()


@pytest.fixture
def valid_plan():
    return {
        "metadata": {"feature": "test", "engine": "unity"},
        "steps": [
            {
                "id": 1,
                "title": "Step 1",
                "instruction": "Do X",
                "files_to_read": [],
                "files_to_edit": ["Assets/Scripts/A.cs"],
                "acceptance_criteria": ["compiles"],
                "depends_on": [],
                "art_dependencies": [],
            },
            {
                "id": 2,
                "title": "Step 2",
                "instruction": "Do Y",
                "files_to_read": [],
                "files_to_edit": ["Assets/Scripts/B.cs"],
                "acceptance_criteria": ["compiles"],
                "depends_on": [1],
                "art_dependencies": [],
            },
        ],
    }


class TestPlanValidator:
    def test_valid_plan_passes(self, validator, valid_plan):
        result = validator.validate(valid_plan)
        assert result.ok
        assert result.errors == []

    def test_missing_required_field(self, validator):
        plan = {"metadata": {}, "steps": [{"id": 1, "title": "X"}]}
        result = validator.validate(plan)
        assert not result.ok
        assert any("instruction" in e for e in result.errors)

    def test_invalid_dependency_reference(self, validator):
        plan = {
            "metadata": {},
            "steps": [
                {
                    "id": 1, "title": "X", "instruction": "Y",
                    "files_to_edit": ["a.cs"], "acceptance_criteria": ["ok"],
                    "depends_on": [99],  # does not exist
                },
            ],
        }
        result = validator.validate(plan)
        assert not result.ok
        assert any("99" in e for e in result.errors)

    def test_engine_internal_file_rejected(self, validator):
        plan = {
            "metadata": {},
            "steps": [
                {
                    "id": 1, "title": "X", "instruction": "Y",
                    "files_to_edit": ["Packages/com.unity.render/foo.cs"],
                    "acceptance_criteria": ["ok"],
                    "depends_on": [],
                },
            ],
        }
        result = validator.validate(plan)
        assert not result.ok
        assert any("engine file" in e.lower() or "Packages/" in e for e in result.errors)

    def test_circular_dependency_detected(self, validator):
        plan = {
            "metadata": {},
            "steps": [
                {
                    "id": 1, "title": "A", "instruction": "X",
                    "files_to_edit": ["a.cs"], "acceptance_criteria": ["ok"],
                    "depends_on": [2],
                },
                {
                    "id": 2, "title": "B", "instruction": "Y",
                    "files_to_edit": ["b.cs"], "acceptance_criteria": ["ok"],
                    "depends_on": [1],
                },
            ],
        }
        result = validator.validate(plan)
        assert not result.ok
        assert any("circular" in e.lower() for e in result.errors)

    def test_topological_sort(self, validator, valid_plan):
        """validate() returns sorted steps when valid."""
        result = validator.validate(valid_plan)
        assert result.ok
        assert result.sorted_step_ids == [1, 2]
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_validator.py -v`
Expected: FAIL

- [ ] **Step 3: Implement PlanValidator**

`src/maliang/core/validator.py`:
```python
"""Plan validation — structure, dependencies, file scope."""
from __future__ import annotations

from graphlib import TopologicalSorter, CycleError

from maliang.core.models import ValidationResult as _BaseValidationResult


class PlanValidationResult(_BaseValidationResult):
    sorted_step_ids: list[int] = []


class PlanValidator:
    REQUIRED_STEP_FIELDS = [
        "id", "title", "instruction", "files_to_edit", "acceptance_criteria",
    ]
    FORBIDDEN_PATH_PREFIXES = ["Packages/", "Library/", "ProjectSettings/"]

    def validate(self, plan: dict) -> PlanValidationResult:
        errors: list[str] = []
        steps = plan.get("steps", [])
        step_ids = {s["id"] for s in steps if "id" in s}

        for step in steps:
            # required fields
            for field in self.REQUIRED_STEP_FIELDS:
                if field not in step:
                    errors.append(f"Step {step.get('id', '?')}: missing '{field}'")

            # dependency references valid
            for dep in step.get("depends_on", []):
                if dep not in step_ids:
                    errors.append(f"Step {step.get('id', '?')}: depends_on {dep} not found")

            # no engine-internal files
            for f in step.get("files_to_edit", []):
                if any(f.startswith(p) for p in self.FORBIDDEN_PATH_PREFIXES):
                    errors.append(
                        f"Step {step.get('id', '?')}: cannot edit engine file {f}"
                    )

        # circular dependency check via topological sort
        sorted_ids: list[int] = []
        if not errors:
            graph: dict[int, set[int]] = {}
            for step in steps:
                graph[step["id"]] = set(step.get("depends_on", []))
            try:
                sorter = TopologicalSorter(graph)
                sorted_ids = list(sorter.static_order())
            except CycleError:
                errors.append("Circular dependency detected in step depends_on")

        return PlanValidationResult(
            ok=len(errors) == 0,
            errors=errors,
            sorted_step_ids=sorted_ids,
        )
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_validator.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/core/validator.py tests/test_validator.py
git commit -m "feat: PlanValidator with topological sort, cycle detection, file scope"
```

---

## Task 6: PipelineState (Persistence)

**Files:**
- Create: `src/maliang/core/state.py`
- Create: `tests/test_state.py`

- [ ] **Step 1: Write failing tests**

`tests/test_state.py`:
```python
"""Tests for PipelineState persistence."""
import json
import pytest
from maliang.core.state import PipelineState
from maliang.core.models import PausePolicy, ExternalDep, StepState


class TestPipelineState:
    def test_new_state(self):
        state = PipelineState.new("feature", PausePolicy.GUIDED)
        assert state.pipeline_name == "feature"
        assert state.current_phase == ""
        assert state.status == "running"

    def test_save_and_load(self, tmp_state_dir):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        state.state_dir = tmp_state_dir / "state"
        state.current_phase = "design"
        state.accumulated_decisions.append("use interfaces")
        state.save()

        loaded = PipelineState.load(tmp_state_dir / "state")
        assert loaded is not None
        assert loaded.pipeline_name == "feature"
        assert loaded.current_phase == "design"
        assert loaded.accumulated_decisions == ["use interfaces"]

    def test_load_nonexistent_returns_none(self, tmp_state_dir):
        result = PipelineState.load(tmp_state_dir / "state")
        assert result is None

    def test_complete_phase(self):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        state.complete_phase("design")
        assert state.is_phase_completed("design")
        assert not state.is_phase_completed("plan")

    def test_substep_complete_and_check(self):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        from maliang.core.models import TaskResult
        result = TaskResult(files_modified=["a.cs"])
        state.complete_substep(1, result)
        assert state.is_substep_completed(1)
        assert not state.is_substep_completed(2)

    def test_mark_blocked(self):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        state.mark_blocked(3, "waiting on art")
        blocked = state.get_blocked_substeps()
        assert 3 in [s.id for s in blocked]

    def test_mark_failed(self):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        state.mark_failed(2, "compile error")
        step = state._get_or_create_step(2)
        assert step.status == "failed"
        assert step.failure_reason == "compile error"

    def test_rewind_to_clears_phase(self):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        state.complete_phase("design")
        state.complete_phase("plan")
        state.complete_phase("execute")
        state.rewind_to("plan")
        assert state.is_phase_completed("design")
        assert not state.is_phase_completed("plan")
        assert not state.is_phase_completed("execute")

    def test_abort(self):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        state.abort()
        assert state.status == "aborted"

    def test_skip_phase(self):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        state.skip_phase("design")
        assert state.is_phase_completed("design")

    def test_external_deps_persisted(self, tmp_state_dir):
        state = PipelineState.new("feature", PausePolicy.AUTO)
        state.state_dir = tmp_state_dir / "state"
        state.external_deps.append(ExternalDep(id="art:x", spec={"w": 96}))
        state.save()
        loaded = PipelineState.load(tmp_state_dir / "state")
        assert len(loaded.external_deps) == 1
        assert loaded.external_deps[0].id == "art:x"
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_state.py -v`
Expected: FAIL

- [ ] **Step 3: Implement PipelineState**

`src/maliang/core/state.py`:
```python
"""PipelineState — JSON-persisted pipeline state, single source of truth."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from pydantic import BaseModel, Field

from maliang.core.models import (
    ExternalDep,
    PausePolicy,
    StepState,
    TaskResult,
)

PIPELINE_STATE_FILE = "pipeline.json"


class PipelineState(BaseModel):
    """Persisted as JSON in .maliang/state/pipeline.json."""

    pipeline_name: str = ""
    current_phase: str = ""
    status: str = "running"  # running | awaiting_decision | blocked | completed | aborted
    pause_policy: PausePolicy = PausePolicy.GUIDED
    completed_phases: list[str] = Field(default_factory=list)
    substeps: dict[int, StepState] = Field(default_factory=dict)
    external_deps: list[ExternalDep] = Field(default_factory=list)
    accumulated_decisions: list[str] = Field(default_factory=list)
    started_at: str = ""
    updated_at: str = ""

    # not persisted — set after load
    state_dir: Path | None = Field(default=None, exclude=True)

    @classmethod
    def new(cls, pipeline_name: str, pause_policy: PausePolicy) -> PipelineState:
        now = datetime.now(timezone.utc).isoformat()
        return cls(
            pipeline_name=pipeline_name,
            pause_policy=pause_policy,
            started_at=now,
            updated_at=now,
        )

    @classmethod
    def load(cls, state_dir: Path) -> PipelineState | None:
        path = state_dir / PIPELINE_STATE_FILE
        if not path.exists():
            return None
        data = json.loads(path.read_text())
        state = cls.model_validate(data)
        state.state_dir = state_dir
        return state

    def save(self) -> None:
        if self.state_dir is None:
            return
        self.updated_at = datetime.now(timezone.utc).isoformat()
        path = self.state_dir / PIPELINE_STATE_FILE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2))

    # --- Phase management ---

    def is_phase_completed(self, phase_name: str) -> bool:
        return phase_name in self.completed_phases

    def complete_phase(self, phase_name: str) -> None:
        if phase_name not in self.completed_phases:
            self.completed_phases.append(phase_name)

    def skip_phase(self, phase_name: str) -> None:
        self.complete_phase(phase_name)

    def rewind_to(self, target_phase: str) -> None:
        """Remove target and all subsequent phases from completed list."""
        if target_phase in self.completed_phases:
            idx = self.completed_phases.index(target_phase)
            self.completed_phases = self.completed_phases[:idx]
        # Clear substep state for execute phase rewinding
        self.substeps.clear()

    def abort(self) -> None:
        self.status = "aborted"

    # --- Substep management ---

    def _get_or_create_step(self, step_id: int) -> StepState:
        if step_id not in self.substeps:
            self.substeps[step_id] = StepState(id=step_id)
        return self.substeps[step_id]

    def is_substep_completed(self, step_id: int) -> bool:
        step = self.substeps.get(step_id)
        return step is not None and step.status == "completed"

    def complete_substep(self, step_id: int, result: TaskResult) -> None:
        step = self._get_or_create_step(step_id)
        step.status = "completed"
        step.result = result

    def mark_blocked(self, step_id: int, reason: str | list) -> None:
        step = self._get_or_create_step(step_id)
        step.status = "blocked"
        step.failure_reason = str(reason)

    def mark_failed(self, step_id: int, reason: str | list) -> None:
        step = self._get_or_create_step(step_id)
        step.status = "failed"
        step.failure_reason = str(reason)

    def record_partial(self, step_id: int, checks: object) -> None:
        step = self._get_or_create_step(step_id)
        step.status = "partial"
        step.failure_reason = str(checks)

    def get_blocked_substeps(self) -> list[StepState]:
        return [s for s in self.substeps.values() if s.status == "blocked"]

    def has_blocked_substeps(self) -> bool:
        return any(s.status == "blocked" for s in self.substeps.values())
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_state.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/core/state.py tests/test_state.py
git commit -m "feat: PipelineState with JSON persistence, phase/substep management, resume"
```

---

## Task 7: StepExecutor (Substep Runner)

**Files:**
- Create: `src/maliang/core/executor.py`
- Create: `tests/test_executor.py`

- [ ] **Step 1: Write failing tests**

`tests/test_executor.py`:
```python
"""Tests for StepExecutor — the substep runner."""
import pytest
from unittest.mock import AsyncMock, MagicMock
from maliang.core.executor import StepExecutor
from maliang.core.models import (
    PausePolicy, TaskResult, StepOutcome, CompileResult, ExternalDep,
)
from maliang.core.state import PipelineState
from maliang.core.events import EventBus


def make_plan(steps):
    """Helper to create a plan dict."""
    return {"metadata": {"engine": "unity"}, "steps": steps}


def make_step(id, depends_on=None, art_deps=None):
    return {
        "id": id,
        "title": f"Step {id}",
        "instruction": f"Do step {id}",
        "files_to_read": [],
        "files_to_edit": [f"file{id}.cs"],
        "acceptance_criteria": ["compiles"],
        "depends_on": depends_on or [],
        "art_dependencies": art_deps or [],
    }


@pytest.fixture
def mock_agent():
    agent = AsyncMock()
    agent.execute.return_value = TaskResult(
        files_modified=["file1.cs"],
        decisions_made=["decision1"],
    )
    return agent


@pytest.fixture
def mock_engine():
    engine = AsyncMock()
    engine.name = "unity"
    engine.compile.return_value = CompileResult(ok=True)
    engine.get_changed_files.return_value = set()
    engine.get_untracked_files.return_value = set()
    return engine


@pytest.fixture
def mock_dep_mgr():
    mgr = MagicMock()
    mgr.deps = {}
    mgr.get_unmet_for_step.return_value = []
    mgr.get_assets_for_step.return_value = {}
    mgr.request = AsyncMock()
    return mgr


@pytest.fixture
def state(tmp_state_dir):
    s = PipelineState.new("feature", PausePolicy.AUTO)
    s.state_dir = tmp_state_dir / "state"
    return s


@pytest.fixture
def executor(mock_agent, mock_engine, mock_dep_mgr):
    bus = EventBus()
    return StepExecutor(
        agent=mock_agent,
        engine=mock_engine,
        bus=bus,
        dep_mgr=mock_dep_mgr,
        style_guide="",
    )


class TestStepExecutor:
    async def test_simple_plan_completes(self, executor, state):
        plan = make_plan([make_step(1), make_step(2, depends_on=[1])])
        outcome = await executor.run_plan(plan, state)
        assert outcome == StepOutcome.COMPLETED
        assert state.is_substep_completed(1)
        assert state.is_substep_completed(2)

    async def test_respects_depends_on_order(self, executor, state, mock_agent):
        """Step 2 depends on 1, even if listed first in YAML."""
        plan = make_plan([
            make_step(2, depends_on=[1]),
            make_step(1),
        ])
        call_order = []
        original_execute = mock_agent.execute

        async def track_execute(task):
            call_order.append(task.instruction)
            return await original_execute(task)

        mock_agent.execute = track_execute
        await executor.run_plan(plan, state)
        assert call_order == ["Do step 1", "Do step 2"]

    async def test_compile_failure_blocks(self, executor, state, mock_engine):
        mock_engine.compile.return_value = CompileResult(ok=False, errors=["CS0001"])
        state.pause_policy = PausePolicy.MANUAL
        plan = make_plan([make_step(1)])
        outcome = await executor.run_plan(plan, state)
        assert outcome == StepOutcome.BLOCKED

    async def test_scope_violation_detected(self, executor, state, mock_engine):
        # Agent modifies a file not in whitelist
        mock_engine.get_changed_files.side_effect = [
            set(),                     # before
            {"file1.cs", "rogue.cs"},  # after
        ]
        plan = make_plan([make_step(1)])
        outcome = await executor.run_plan(plan, state)
        # auto mode: continues past failure
        assert not state.is_substep_completed(1)

    async def test_resume_skips_completed(self, executor, state, mock_agent):
        state.complete_substep(1, TaskResult())
        plan = make_plan([make_step(1), make_step(2)])
        await executor.run_plan(plan, state)
        # Agent should only be called once (for step 2)
        assert mock_agent.execute.call_count == 1

    async def test_external_dep_blocking(self, executor, state, mock_dep_mgr):
        blocking_dep = ExternalDep(id="art:x", status="pending", blocking=True)
        mock_dep_mgr.get_unmet_for_step.return_value = [blocking_dep]
        plan = make_plan([make_step(1)])
        outcome = await executor.run_plan(plan, state)
        assert outcome == StepOutcome.WAITING_ON_DEPS

    async def test_placeholder_allows_progress(self, executor, state, mock_dep_mgr):
        dep = ExternalDep(id="art:x", status="pending", blocking=False, placeholder="p.png")
        mock_dep_mgr.get_unmet_for_step.return_value = [dep]
        plan = make_plan([make_step(1)])
        outcome = await executor.run_plan(plan, state)
        assert outcome == StepOutcome.COMPLETED
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_executor.py -v`
Expected: FAIL

- [ ] **Step 3: Implement StepExecutor**

`src/maliang/core/executor.py`:
```python
"""StepExecutor — fine-grained substep runner for the execute phase."""
from __future__ import annotations

from graphlib import TopologicalSorter

from maliang.core.events import EventBus
from maliang.core.models import (
    ExternalDep,
    PausePolicy,
    StepOutcome,
    TaskSpec,
    CompileResult,
)
from maliang.core.state import PipelineState


class StepExecutor:
    def __init__(self, agent, engine, bus: EventBus, dep_mgr, style_guide: str = ""):
        self.agent = agent
        self.engine = engine
        self.bus = bus
        self.dep_mgr = dep_mgr
        self.style_guide = style_guide

    async def run_plan(self, plan: dict, state: PipelineState) -> StepOutcome:
        steps = plan["steps"]
        ordered = self._topological_sort(steps)

        # Auto-request unregistered art deps
        for substep in ordered:
            for art_dep in substep.get("art_dependencies", []):
                dep_id = art_dep["id"] if isinstance(art_dep, dict) else art_dep.id
                if dep_id not in self.dep_mgr.deps:
                    await self.dep_mgr.request(ExternalDep(
                        id=dep_id,
                        kind="art_asset",
                        spec=art_dep.get("spec", {}) if isinstance(art_dep, dict) else {},
                        status="pending",
                        placeholder=art_dep.get("placeholder") if isinstance(art_dep, dict) else None,
                        blocking=art_dep.get("blocking", True) if isinstance(art_dep, dict) else True,
                    ))

        for substep in ordered:
            step_id = substep["id"]
            if state.is_substep_completed(step_id):
                continue

            # 1. Internal dependency check
            internal_unmet = [
                d for d in substep.get("depends_on", [])
                if not state.is_substep_completed(d)
            ]
            if internal_unmet:
                state.mark_blocked(step_id, f"waiting on steps: {internal_unmet}")
                state.save()
                self.bus.emit("substep.blocked", substep_id=step_id, reason="internal_deps")
                continue

            # 1b. External dependency check
            external_unmet = self.dep_mgr.get_unmet_for_step(substep)
            truly_blocking = [
                d for d in external_unmet
                if d.blocking or not d.placeholder
            ]
            if truly_blocking:
                state.mark_blocked(step_id, [d.id for d in truly_blocking])
                state.save()
                self.bus.emit("substep.blocked", substep_id=step_id, reason="external_deps")
                continue

            if [d for d in external_unmet if d.placeholder]:
                self.bus.emit("substep.using_placeholder", substep_id=step_id)

            # 2. Build TaskSpec
            task = TaskSpec(
                instruction=substep["instruction"],
                acceptance_criteria=substep.get("acceptance_criteria", []),
                files_to_read=substep.get("files_to_read", []),
                files_to_edit=substep.get("files_to_edit", []),
                prior_decisions=list(state.accumulated_decisions),
                available_assets=self.dep_mgr.get_assets_for_step(substep),
                engine=self.engine.name,
                style_guide=self.style_guide,
            )

            # 3. Snapshot + call agent
            before_changed = await self.engine.get_changed_files()
            before_created = await self.engine.get_untracked_files()

            self.bus.emit("substep.agent_calling", substep_id=step_id)
            result = await self.agent.execute(task)

            # 3.5. File scope check
            after_changed = await self.engine.get_changed_files()
            after_created = await self.engine.get_untracked_files()
            agent_modified = after_changed - before_changed
            agent_created = after_created - before_created
            all_touched = agent_modified | agent_created
            allowed = set(task.files_to_edit)
            out_of_scope = all_touched - allowed

            if out_of_scope:
                await self.engine.revert_files(agent_modified & out_of_scope)
                await self.engine.delete_files(agent_created & out_of_scope)
                state.mark_failed(step_id, f"Out-of-scope files: {out_of_scope}")
                state.save()
                self.bus.emit("substep.scope_violation", substep_id=step_id)
                if state.pause_policy != PausePolicy.AUTO:
                    return StepOutcome.BLOCKED
                continue

            if len(agent_created) > task.max_new_files:
                state.mark_failed(step_id, f"Too many files: {len(agent_created)}")
                state.save()
                self.bus.emit("substep.scope_violation", substep_id=step_id)
                if state.pause_policy != PausePolicy.AUTO:
                    return StepOutcome.BLOCKED
                continue

            # 4. Compile
            compile_result = await self.engine.compile()
            if not compile_result.ok:
                fix_result = await self._try_fix_compile(task, compile_result)
                if not fix_result:
                    state.mark_failed(step_id, compile_result.errors)
                    state.save()
                    self.bus.emit("substep.compile_failed", substep_id=step_id)
                    if state.pause_policy != PausePolicy.AUTO:
                        return StepOutcome.BLOCKED
                    continue
                result = fix_result

            # 5. Acceptance check (simplified for MVP: compile is the check)
            # Full acceptance check engine will be added in future iteration

            # 5.5 Agent questions
            if result.questions:
                state.accumulated_decisions.append(
                    f"[pending questions from step {step_id}] {'; '.join(result.questions)}"
                )
                if state.pause_policy != PausePolicy.AUTO:
                    self.bus.emit("substep.questions", substep_id=step_id)
                    return StepOutcome.BLOCKED

            # 6. Harvest decisions
            state.accumulated_decisions.extend(result.decisions_made)

            # 7. Advance
            state.complete_substep(step_id, result)
            self.bus.emit("substep.completed", substep_id=step_id, title=substep["title"])
            state.save()

        blocked = state.get_blocked_substeps()
        if blocked:
            return StepOutcome.WAITING_ON_DEPS
        return StepOutcome.COMPLETED

    async def _try_fix_compile(self, task, compile_result, max_retries=2):
        """Give agent a chance to fix compile errors."""
        for _ in range(max_retries):
            fix_task = TaskSpec(
                instruction=f"Fix compile errors: {compile_result.errors}",
                acceptance_criteria=["compiles"],
                files_to_read=task.files_to_read,
                files_to_edit=task.files_to_edit,
                prior_decisions=task.prior_decisions,
                engine=task.engine,
                style_guide=task.style_guide,
                available_assets=task.available_assets,
            )
            result = await self.agent.execute(fix_task)
            compile_result = await self.engine.compile()
            if compile_result.ok:
                return result
        return None

    def _topological_sort(self, steps: list[dict]) -> list[dict]:
        graph = {s["id"]: set(s.get("depends_on", [])) for s in steps}
        sorter = TopologicalSorter(graph)
        order = list(sorter.static_order())
        step_by_id = {s["id"]: s for s in steps}
        return [step_by_id[sid] for sid in order]
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_executor.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/core/executor.py tests/test_executor.py
git commit -m "feat: StepExecutor — topological sort, scope check, compile gate, resume"
```

---

## Task 8: PipelineRunner (Main Loop)

**Files:**
- Create: `src/maliang/core/runner.py`
- Create: `tests/test_runner.py`

- [ ] **Step 1: Write failing tests**

`tests/test_runner.py`:
```python
"""Tests for PipelineRunner."""
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from maliang.core.runner import PipelineRunner
from maliang.core.models import (
    PausePolicy, RunOutcome, TaskResult, CompileResult, TestResult,
)
from maliang.core.state import PipelineState
from maliang.core.events import EventBus


@pytest.fixture
def mock_agent():
    agent = AsyncMock()
    agent.execute.return_value = TaskResult()
    agent.design.return_value = "design doc content"
    agent.plan.return_value = {"metadata": {}, "steps": []}
    agent.review.return_value = MagicMock(ok=True, critical_count=0)
    return agent


@pytest.fixture
def mock_engine():
    engine = AsyncMock()
    engine.name = "unity"
    engine.compile.return_value = CompileResult(ok=True)
    engine.run_tests.return_value = TestResult(ok=True, passed=5)
    engine.get_changed_files.return_value = set()
    engine.get_untracked_files.return_value = set()
    return engine


@pytest.fixture
def mock_dep_mgr():
    mgr = MagicMock()
    mgr.deps = {}
    mgr.get_unmet_for_step.return_value = []
    mgr.get_assets_for_step.return_value = {}
    mgr.request = AsyncMock()
    mgr.check_inbox = AsyncMock()
    return mgr


@pytest.fixture
def runner(mock_agent, mock_engine, mock_dep_mgr, tmp_state_dir):
    bus = EventBus()
    state = PipelineState.new("prototype", PausePolicy.AUTO)
    state.state_dir = tmp_state_dir / "state"
    return PipelineRunner(
        agent=mock_agent,
        engine=mock_engine,
        bus=bus,
        dep_mgr=mock_dep_mgr,
        state=state,
    )


class TestPipelineRunner:
    async def test_prototype_pipeline_completes(self, runner):
        """Prototype: execute → commit. Both should complete in auto mode."""
        # Mock the plan loading and execution
        runner.load_plan = MagicMock(return_value={
            "metadata": {}, "steps": [
                {"id": 1, "title": "X", "instruction": "do X",
                 "files_to_edit": ["a.cs"], "acceptance_criteria": [],
                 "depends_on": [], "art_dependencies": []},
            ],
        })
        outcome = await runner.run()
        assert outcome == RunOutcome.COMPLETED

    async def test_manual_mode_pauses(self, runner):
        runner.state.pause_policy = PausePolicy.MANUAL
        outcome = await runner.run()
        assert outcome == RunOutcome.AWAITING_DECISION
        assert runner.state.status == "awaiting_decision"

    async def test_on_decision_proceed(self, runner):
        runner.state.pause_policy = PausePolicy.MANUAL
        runner.state.status = "awaiting_decision"
        runner.state.current_phase = "execute"
        # After proceed, should try to run
        runner.load_plan = MagicMock(return_value={"metadata": {}, "steps": []})
        await runner.on_decision("proceed")
        assert runner.state.status == "running"

    async def test_on_decision_abort(self, runner):
        await runner.on_decision("abort")
        assert runner.state.status == "aborted"

    async def test_state_persisted_on_phase_complete(self, runner, tmp_state_dir):
        runner.load_plan = MagicMock(return_value={"metadata": {}, "steps": []})
        await runner.run()
        # State file should exist
        state_file = tmp_state_dir / "state" / "pipeline.json"
        assert state_file.exists()
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_runner.py -v`
Expected: FAIL

- [ ] **Step 3: Implement PipelineRunner**

`src/maliang/core/runner.py`:
```python
"""PipelineRunner — the main loop that drives the pipeline FSM."""
from __future__ import annotations

from pathlib import Path
from typing import Any

from maliang.core.events import EventBus
from maliang.core.executor import StepExecutor
from maliang.core.models import (
    PausePolicy,
    PauseLevel,
    PhaseOutcome,
    RunOutcome,
    StepOutcome,
)
from maliang.core.pipeline import PIPELINES, Phase
from maliang.core.state import PipelineState


class PipelineRunner:
    def __init__(
        self,
        agent,
        engine,
        bus: EventBus,
        dep_mgr,
        state: PipelineState,
    ):
        self.agent = agent
        self.engine = engine
        self.bus = bus
        self.dep_mgr = dep_mgr
        self.state = state
        self.step_executor = StepExecutor(agent, engine, bus, dep_mgr)

    async def run(self) -> RunOutcome:
        pipeline = PIPELINES[self.state.pipeline_name]
        self.bus.emit("pipeline.started",
                      pipeline=self.state.pipeline_name,
                      policy=self.state.pause_policy.value)

        for phase in pipeline.phases:
            if self.state.is_phase_completed(phase.name):
                continue

            self.state.current_phase = phase.name
            self.state.save()
            self.bus.emit("pipeline.phase.entering", phase=phase.name)

            if self._should_pause(phase):
                self.state.status = "awaiting_decision"
                self.state.save()
                self.bus.emit("decision.awaiting",
                              prompt=f"About to start '{phase.name}'. Proceed?",
                              options=["proceed", "skip", "abort"])
                return RunOutcome.AWAITING_DECISION

            outcome = await self._run_phase(phase)

            if isinstance(outcome, PhaseOutcome.COMPLETED):
                self.state.complete_phase(phase.name)
                self.bus.emit("pipeline.phase.completed", phase=phase.name)
                self.state.save()
            elif isinstance(outcome, PhaseOutcome.RETRY):
                self.state.rewind_to(outcome.goto)
                self.state.save()
                self.bus.emit("pipeline.phase.rewound", target=outcome.goto)
                return await self.run()
            elif isinstance(outcome, PhaseOutcome.BLOCKED):
                self.state.save()
                self.bus.emit("pipeline.blocked", phase=phase.name)
                return RunOutcome.BLOCKED
            elif isinstance(outcome, PhaseOutcome.FAILED):
                self.state.save()
                self.bus.emit("pipeline.failed", phase=phase.name, error=outcome.error)
                return RunOutcome.FAILED

        self.state.status = "completed"
        self.state.save()
        self.bus.emit("pipeline.completed")
        return RunOutcome.COMPLETED

    async def _run_phase(self, phase: Phase) -> Any:
        if phase.executor == "substep_runner":
            plan = self.load_plan()
            step_outcome = await self.step_executor.run_plan(plan, self.state)
            match step_outcome:
                case StepOutcome.COMPLETED:
                    return PhaseOutcome.COMPLETED()
                case StepOutcome.BLOCKED:
                    return PhaseOutcome.BLOCKED()
                case StepOutcome.WAITING_ON_DEPS:
                    return PhaseOutcome.BLOCKED()
                case _:
                    return PhaseOutcome.FAILED("unexpected step outcome")
        elif phase.engine_task:
            result = await getattr(self.engine, phase.engine_task)()
            if not result.ok:
                if phase.on_fail:
                    return PhaseOutcome.RETRY(goto=phase.on_fail.goto)
                return PhaseOutcome.FAILED(error=str(result.errors) if hasattr(result, 'errors') else "failed")
            return PhaseOutcome.COMPLETED()
        else:
            # Agent creative task — design, plan, review, commit
            result = await self._run_agent_phase(phase)
            if not result:
                if phase.on_fail:
                    return PhaseOutcome.RETRY(goto=phase.on_fail.goto)
                return PhaseOutcome.FAILED(error="agent phase failed")
            return PhaseOutcome.COMPLETED()

    async def _run_agent_phase(self, phase: Phase) -> bool:
        """Run an agent creative task. Returns True on success."""
        # Delegate to the appropriate agent method based on phase task type
        try:
            if phase.agent_task == "commit":
                await self.agent.execute(self._build_commit_task())
            else:
                await self.agent.execute(self._build_phase_task(phase))
            return True
        except Exception:
            return False

    def _build_phase_task(self, phase: Phase):
        from maliang.core.models import TaskSpec
        return TaskSpec(
            instruction=f"Execute '{phase.agent_task}' phase",
            acceptance_criteria=[],
            files_to_read=[],
            files_to_edit=[],
            prior_decisions=list(self.state.accumulated_decisions),
            engine=self.engine.name,
            style_guide="",
            available_assets={},
        )

    def _build_commit_task(self):
        from maliang.core.models import TaskSpec
        return TaskSpec(
            instruction="Commit all changes and push",
            acceptance_criteria=["pushed"],
            files_to_read=[],
            files_to_edit=[],
            prior_decisions=[],
            engine=self.engine.name,
            style_guide="",
            available_assets={},
        )

    def load_plan(self) -> dict:
        """Load the current plan from .maliang/plans/. Override in tests."""
        import json
        if self.state.state_dir:
            plans_dir = self.state.state_dir.parent / "plans"
            for plan_file in sorted(plans_dir.glob("*.yaml"), reverse=True):
                from ruamel.yaml import YAML
                yaml = YAML()
                return yaml.load(plan_file)
            for plan_file in sorted(plans_dir.glob("*.json"), reverse=True):
                return json.loads(plan_file.read_text())
        return {"metadata": {}, "steps": []}

    def _should_pause(self, phase: Phase) -> bool:
        match self.state.pause_policy:
            case PausePolicy.AUTO:
                return False
            case PausePolicy.MANUAL:
                return True
            case PausePolicy.GUIDED:
                return phase.pause_level == PauseLevel.GATE

    # --- External event handlers ---

    async def on_decision(self, choice: str) -> None:
        self.bus.emit("decision.received", choice=choice)
        match choice:
            case "proceed":
                self.state.status = "running"
                self.state.save()
                await self.run()
            case "skip":
                self.state.skip_phase(self.state.current_phase)
                self.state.save()
                await self.run()
            case "abort":
                self.state.abort()
                self.state.save()

    async def on_external_delivery(self, dep_id: str, artifact: Path) -> None:
        self.dep_mgr.receive(dep_id, artifact)
        if self.state.has_blocked_substeps():
            await self.run()

    async def on_external_question(self, dep_id: str, question: str) -> None:
        self.bus.emit("external.question", dep_id=dep_id, question=question)

    async def answer_external_question(self, dep_id: str, answer: str) -> None:
        await self.dep_mgr.answer_question(dep_id, answer)
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_runner.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/core/runner.py tests/test_runner.py
git commit -m "feat: PipelineRunner — FSM main loop, phase execution, pause/resume/abort"
```

---

## Task 9: Agent Adapter Protocol + Base

**Files:**
- Create: `src/maliang/agents/__init__.py`
- Create: `src/maliang/agents/base.py`
- Create: `tests/test_agents.py`

- [ ] **Step 1: Write failing tests**

`tests/test_agents.py`:
```python
"""Tests for agent adapter protocol."""
from maliang.agents.base import AgentAdapter
from maliang.core.models import TaskSpec, TaskResult


class TestAgentProtocol:
    def test_protocol_defined(self):
        """AgentAdapter is a Protocol with execute method."""
        assert hasattr(AgentAdapter, "execute")

    def test_mock_implements_protocol(self):
        """A mock with execute() satisfies the protocol."""
        class MockAgent:
            async def execute(self, task: TaskSpec) -> TaskResult:
                return TaskResult()

        agent = MockAgent()
        assert hasattr(agent, "execute")
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_agents.py -v`
Expected: FAIL

- [ ] **Step 3: Implement agent base**

`src/maliang/agents/__init__.py`:
```python
"""Agent adapters — pluggable LLM backends."""
```

`src/maliang/agents/base.py`:
```python
"""AgentAdapter protocol — the contract between orchestrator and LLM."""
from __future__ import annotations

from typing import Protocol, runtime_checkable

from maliang.core.models import TaskSpec, TaskResult


@runtime_checkable
class AgentAdapter(Protocol):
    """Agent sees a task, returns a result. No pipeline awareness."""

    async def execute(self, task: TaskSpec) -> TaskResult: ...
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_agents.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/agents/ tests/test_agents.py
git commit -m "feat: AgentAdapter protocol — runtime-checkable interface for LLM backends"
```

---

## Task 10: ClaudeAdapter

**Files:**
- Create: `src/maliang/agents/claude.py`
- Create: `src/maliang/agents/prompts.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_agents.py`:
```python
from maliang.agents.claude import ClaudeAdapter


class TestClaudeAdapter:
    def test_instantiation(self):
        adapter = ClaudeAdapter(model="claude-sonnet-4-6")
        assert adapter.model == "claude-sonnet-4-6"

    def test_render_prompt(self):
        adapter = ClaudeAdapter()
        task = TaskSpec(
            instruction="Implement X",
            acceptance_criteria=["compiles", "has tests"],
            files_to_read=["context.cs"],
            files_to_edit=["target.cs"],
            prior_decisions=["use interface pattern"],
            engine="unity",
            style_guide="follow conventions",
            available_assets={},
        )
        prompt = adapter._render_prompt(task)
        assert "Implement X" in prompt
        assert "compiles" in prompt
        assert "use interface pattern" in prompt
        assert "target.cs" in prompt
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_agents.py::TestClaudeAdapter -v`
Expected: FAIL

- [ ] **Step 3: Implement ClaudeAdapter and prompts**

`src/maliang/agents/prompts.py`:
```python
"""Prompt templates for agent tasks."""
from __future__ import annotations

from maliang.core.models import TaskSpec


def render_execute_prompt(task: TaskSpec) -> str:
    sections = [
        f"## Task\n{task.instruction}",
        f"## Acceptance Criteria\n" + "\n".join(f"- {c}" for c in task.acceptance_criteria),
    ]
    if task.prior_decisions:
        sections.append(
            "## Context from Previous Steps\n"
            + "\n".join(f"- {d}" for d in task.prior_decisions)
        )
    if task.available_assets:
        import json
        sections.append(f"## Available Assets\n```json\n{json.dumps(task.available_assets, indent=2)}\n```")
    if task.style_guide:
        sections.append(f"## Style Guide\n{task.style_guide}")
    return "\n\n".join(sections)


def render_system_prompt(task: TaskSpec) -> str:
    return f"""You are implementing ONE step of a plan.
You may ONLY modify these files: {', '.join(task.files_to_edit)}
You may read these files for context: {', '.join(task.files_to_read)}
Do NOT create files outside the project structure.
Do NOT refactor code beyond what this step requires.
Engine: {task.engine}

When done, output a JSON block with this exact structure:
{{"decisions_made": [...], "questions": [...], "self_assessment": "complete"}}"""
```

`src/maliang/agents/claude.py`:
```python
"""ClaudeAdapter — calls Claude via Agent SDK as a stateless function."""
from __future__ import annotations

import json
import re

from maliang.agents.prompts import render_execute_prompt, render_system_prompt
from maliang.core.models import TaskSpec, TaskResult


class ClaudeAdapter:
    def __init__(self, model: str = "claude-sonnet-4-6", max_retries: int = 3):
        self.model = model
        self.max_retries = max_retries

    async def execute(self, task: TaskSpec) -> TaskResult:
        """Call Claude Agent SDK. Each call is stateless — no session memory."""
        try:
            from claude_agent_sdk import query as claude_query
        except ImportError:
            raise RuntimeError(
                "claude-agent-sdk not installed. Install with: pip install claude-agent-sdk"
            )

        prompt = self._render_prompt(task)
        raw_output_parts: list[str] = []

        async for msg in claude_query(
            prompt=prompt,
            model=self.model,
            allowed_tools=["Read", "Edit", "Write", "Glob", "Grep", "Bash"],
            disallowed_tools=["Agent"],
            max_turns=task.max_turns,
            permission_mode="acceptEdits",
            system_prompt=render_system_prompt(task),
        ):
            if hasattr(msg, "content"):
                raw_output_parts.append(str(msg.content))

        raw_output = "\n".join(raw_output_parts)
        return self._parse_result(raw_output)

    def _render_prompt(self, task: TaskSpec) -> str:
        return render_execute_prompt(task)

    def _parse_result(self, raw_output: str) -> TaskResult:
        """Extract structured JSON from agent output, fall back to defaults."""
        # Try to find JSON block in output
        json_match = re.search(r'\{[^{}]*"decisions_made"[^{}]*\}', raw_output, re.DOTALL)
        if json_match:
            try:
                data = json.loads(json_match.group())
                return TaskResult(
                    decisions_made=data.get("decisions_made", []),
                    questions=data.get("questions", []),
                    self_assessment=data.get("self_assessment", "complete"),
                    raw_output=raw_output,
                )
            except json.JSONDecodeError:
                pass

        return TaskResult(raw_output=raw_output, self_assessment="complete")
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_agents.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/agents/claude.py src/maliang/agents/prompts.py tests/test_agents.py
git commit -m "feat: ClaudeAdapter + prompt templates — stateless Agent SDK integration"
```

---

## Task 11: Engine Adapter Protocol + Base

**Files:**
- Create: `src/maliang/engines/__init__.py`
- Create: `src/maliang/engines/base.py`
- Create: `tests/test_engine_base.py`

- [ ] **Step 1: Write failing test**

`tests/test_engine_base.py`:
```python
"""Tests for engine adapter protocol."""
from maliang.engines.base import EngineAdapter
from maliang.core.models import CompileResult, TestResult


class TestEngineProtocol:
    def test_protocol_defined(self):
        assert hasattr(EngineAdapter, "compile")
        assert hasattr(EngineAdapter, "run_tests")
        assert hasattr(EngineAdapter, "get_changed_files")
        assert hasattr(EngineAdapter, "get_untracked_files")
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_engine_base.py -v`
Expected: FAIL

- [ ] **Step 3: Implement engine base**

`src/maliang/engines/__init__.py`:
```python
"""Engine adapters — pluggable game engine backends."""
```

`src/maliang/engines/base.py`:
```python
"""EngineAdapter protocol — interface for game engine interaction."""
from __future__ import annotations

from typing import Protocol, runtime_checkable

from maliang.core.models import CompileResult, TestResult


@runtime_checkable
class EngineAdapter(Protocol):
    name: str

    async def compile(self) -> CompileResult: ...
    async def run_tests(self, scope: str = "all") -> TestResult: ...
    async def get_project_state(self) -> dict: ...
    async def get_changed_files(self) -> set[str]: ...
    async def get_untracked_files(self) -> set[str]: ...
    async def revert_files(self, files: set[str]) -> None: ...
    async def delete_files(self, files: set[str]) -> None: ...
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_engine_base.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/engines/ tests/test_engine_base.py
git commit -m "feat: EngineAdapter protocol — compile, test, file scope interface"
```

---

## Task 12: UnityAdapter

**Files:**
- Create: `src/maliang/engines/unity.py`
- Create: `tests/test_unity.py`

- [ ] **Step 1: Write failing tests**

`tests/test_unity.py`:
```python
"""Tests for UnityAdapter."""
import json
import pytest
from pathlib import Path
from unittest.mock import AsyncMock, patch
from maliang.engines.unity import UnityAdapter


@pytest.fixture
def unity(tmp_path):
    return UnityAdapter(project_path=tmp_path)


class TestUnityAdapter:
    def test_name(self, unity):
        assert unity.name == "unity"

    async def test_get_changed_files(self, unity):
        with patch("maliang.engines.unity.run_cmd", new_callable=AsyncMock) as mock:
            mock.return_value = "Assets/Scripts/A.cs\nAssets/Scripts/B.cs\n"
            result = await unity.get_changed_files()
            assert result == {"Assets/Scripts/A.cs", "Assets/Scripts/B.cs"}

    async def test_get_untracked_files(self, unity):
        with patch("maliang.engines.unity.run_cmd", new_callable=AsyncMock) as mock:
            mock.return_value = "Assets/Scripts/New.cs\n"
            result = await unity.get_untracked_files()
            assert result == {"Assets/Scripts/New.cs"}

    async def test_get_changed_files_empty(self, unity):
        with patch("maliang.engines.unity.run_cmd", new_callable=AsyncMock) as mock:
            mock.return_value = ""
            result = await unity.get_changed_files()
            assert result == set()

    async def test_revert_files(self, unity):
        with patch("maliang.engines.unity.run_cmd", new_callable=AsyncMock) as mock:
            mock.return_value = ""
            await unity.revert_files({"a.cs", "b.cs"})
            mock.assert_called_once()

    async def test_delete_files(self, unity, tmp_path):
        f = tmp_path / "rogue.cs"
        f.write_text("bad")
        await unity.delete_files({str(f)})
        assert not f.exists()

    async def test_tykit_detection(self, unity, tmp_path):
        tykit_file = tmp_path / "Temp" / "tykit.json"
        tykit_file.parent.mkdir(parents=True)
        tykit_file.write_text(json.dumps({"port": 27183}))
        port = unity._detect_tykit_port()
        assert port == 27183

    async def test_tykit_not_available(self, unity):
        port = unity._detect_tykit_port()
        assert port is None
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_unity.py -v`
Expected: FAIL

- [ ] **Step 3: Implement UnityAdapter**

`src/maliang/engines/unity.py`:
```python
"""UnityAdapter — three-tier compile: tykit → Editor trigger → batch."""
from __future__ import annotations

import asyncio
import json
import os
import platform
from pathlib import Path

from maliang.core.models import CompileResult, TestResult


async def run_cmd(cmd: str, cwd: Path | None = None, timeout: float = 120) -> str:
    proc = await asyncio.create_subprocess_shell(
        cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=cwd,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise
    return stdout.decode("utf-8", errors="replace").strip()


class UnityAdapter:
    name = "unity"

    def __init__(
        self,
        project_path: Path,
        compile_timeout: float = 120,
        test_timeout: float = 180,
    ):
        self.project_path = Path(project_path)
        self.compile_timeout = compile_timeout
        self.test_timeout = test_timeout

    # --- Compile (three-tier) ---

    async def compile(self) -> CompileResult:
        port = self._detect_tykit_port()
        if port:
            return await self._tykit_compile(port)
        if self._editor_running():
            return await self._editor_trigger_compile()
        return await self._batch_compile()

    async def _tykit_compile(self, port: int) -> CompileResult:
        import aiohttp
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"http://127.0.0.1:{port}/compile",
                    timeout=aiohttp.ClientTimeout(total=self.compile_timeout),
                ) as resp:
                    data = await resp.json()
                    return CompileResult(
                        ok=data.get("success", False),
                        errors=data.get("errors", []),
                        duration=data.get("duration", 0),
                    )
        except Exception as e:
            return CompileResult(ok=False, errors=[str(e)])

    async def _editor_trigger_compile(self) -> CompileResult:
        if platform.system() == "Darwin":
            cmd = 'osascript -e \'tell application "Unity" to activate\''
        else:
            cmd = 'powershell -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait(\'^r\')"'
        try:
            await run_cmd(cmd, timeout=10)
            await asyncio.sleep(3)  # wait for compile to start
            return CompileResult(ok=True)
        except Exception as e:
            return CompileResult(ok=False, errors=[str(e)])

    async def _batch_compile(self) -> CompileResult:
        unity_path = self._find_unity()
        if not unity_path:
            return CompileResult(ok=False, errors=["Unity executable not found"])
        cmd = f'"{unity_path}" -quit -batchmode -projectPath "{self.project_path}" -logFile -'
        try:
            output = await run_cmd(cmd, timeout=self.compile_timeout)
            ok = "compilationfinished" in output.lower() or "refresh completed" in output.lower()
            errors = [line for line in output.split("\n") if "error" in line.lower()]
            return CompileResult(ok=ok or not errors, errors=errors)
        except Exception as e:
            return CompileResult(ok=False, errors=[str(e)])

    # --- Tests ---

    async def run_tests(self, scope: str = "all") -> TestResult:
        port = self._detect_tykit_port()
        if port:
            return await self._tykit_tests(port, scope)
        return await self._batch_tests(scope)

    async def _tykit_tests(self, port: int, scope: str) -> TestResult:
        import aiohttp
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"http://127.0.0.1:{port}/run-tests",
                    json={"scope": scope},
                    timeout=aiohttp.ClientTimeout(total=self.test_timeout),
                ) as resp:
                    data = await resp.json()
                    return TestResult(
                        ok=data.get("passed", 0) > 0 and data.get("failed", 0) == 0,
                        passed=data.get("passed", 0),
                        failed=data.get("failed", 0),
                        failures=data.get("failures", []),
                        duration=data.get("duration", 0),
                    )
        except Exception as e:
            return TestResult(ok=False, failures=[str(e)])

    async def _batch_tests(self, scope: str) -> TestResult:
        unity_path = self._find_unity()
        if not unity_path:
            return TestResult(ok=False, failures=["Unity not found"])
        mode_flag = "-runTests -testPlatform EditMode"
        if scope == "playmode":
            mode_flag = "-runTests -testPlatform PlayMode"
        cmd = f'"{unity_path}" -batchmode -projectPath "{self.project_path}" {mode_flag} -logFile -'
        try:
            output = await run_cmd(cmd, timeout=self.test_timeout)
            return self._parse_test_output(output)
        except Exception as e:
            return TestResult(ok=False, failures=[str(e)])

    def _parse_test_output(self, output: str) -> TestResult:
        passed = output.lower().count("passed")
        failed = output.lower().count("failed")
        failures = [l for l in output.split("\n") if "FAIL" in l]
        return TestResult(ok=failed == 0, passed=passed, failed=failed, failures=failures)

    # --- File scope (git-based) ---

    async def get_project_state(self) -> dict:
        has_library = (self.project_path / "Library").is_dir()
        port = self._detect_tykit_port()
        return {"initialized": has_library, "tykit_port": port}

    async def get_changed_files(self) -> set[str]:
        output = await run_cmd("git diff --name-only", cwd=self.project_path)
        return {f for f in output.split("\n") if f.strip()}

    async def get_untracked_files(self) -> set[str]:
        output = await run_cmd(
            "git ls-files --others --exclude-standard", cwd=self.project_path
        )
        return {f for f in output.split("\n") if f.strip()}

    async def revert_files(self, files: set[str]) -> None:
        if not files:
            return
        file_list = " ".join(f'"{f}"' for f in files)
        await run_cmd(f"git checkout -- {file_list}", cwd=self.project_path)

    async def delete_files(self, files: set[str]) -> None:
        for f in files:
            path = Path(f) if Path(f).is_absolute() else self.project_path / f
            if path.exists():
                path.unlink()

    # --- Utilities ---

    def _detect_tykit_port(self) -> int | None:
        tykit_json = self.project_path / "Temp" / "tykit.json"
        if tykit_json.exists():
            try:
                data = json.loads(tykit_json.read_text())
                return data.get("port")
            except (json.JSONDecodeError, KeyError):
                pass
        return None

    def _editor_running(self) -> bool:
        lock_file = self.project_path / "Temp" / "UnityLockfile"
        return lock_file.exists()

    def _find_unity(self) -> str | None:
        if platform.system() == "Windows":
            candidates = [
                Path(os.environ.get("PROGRAMFILES", "")) / "Unity" / "Hub" / "Editor",
                Path("C:/Program Files/Unity/Hub/Editor"),
            ]
            for base in candidates:
                if base.exists():
                    versions = sorted(base.iterdir(), reverse=True)
                    for v in versions:
                        exe = v / "Editor" / "Unity.exe"
                        if exe.exists():
                            return str(exe)
        elif platform.system() == "Darwin":
            app = Path("/Applications/Unity/Hub/Editor")
            if app.exists():
                versions = sorted(app.iterdir(), reverse=True)
                for v in versions:
                    exe = v / "Unity.app" / "Contents" / "MacOS" / "Unity"
                    if exe.exists():
                        return str(exe)
        return None
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_unity.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/engines/unity.py tests/test_unity.py
git commit -m "feat: UnityAdapter — tykit/editor/batch compile, tests, file scope"
```

---

## Task 13: External Dependency Manager

**Files:**
- Create: `src/maliang/external/__init__.py`
- Create: `src/maliang/external/deps.py`
- Create: `tests/test_deps.py`

- [ ] **Step 1: Write failing tests**

`tests/test_deps.py`:
```python
"""Tests for ExternalDepManager."""
import json
import pytest
from pathlib import Path
from maliang.external.deps import ExternalDepManager
from maliang.core.models import ExternalDep
from maliang.core.state import PipelineState
from maliang.core.models import PausePolicy
from maliang.core.events import EventBus


@pytest.fixture
def state(tmp_state_dir):
    s = PipelineState.new("feature", PausePolicy.AUTO)
    s.state_dir = tmp_state_dir / "state"
    return s


@pytest.fixture
def mgr(tmp_state_dir, state):
    bus = EventBus()
    return ExternalDepManager(
        bus=bus,
        inbox=tmp_state_dir / "inbox",
        outbox=tmp_state_dir / "outbox",
        state=state,
    )


class TestExternalDepManager:
    async def test_request_writes_outbox(self, mgr, tmp_state_dir):
        dep = ExternalDep(id="art:sprite", spec={"w": 96})
        await mgr.request(dep)
        outbox_file = tmp_state_dir / "outbox" / "art:sprite.json"
        assert outbox_file.exists()
        data = json.loads(outbox_file.read_text())
        assert data["id"] == "art:sprite"

    async def test_request_syncs_to_state(self, mgr, state):
        dep = ExternalDep(id="art:x", spec={})
        await mgr.request(dep)
        assert len(state.external_deps) == 1
        assert state.external_deps[0].id == "art:x"

    def test_receive_updates_status(self, mgr):
        mgr.deps["art:x"] = ExternalDep(id="art:x", status="pending")
        mgr.receive("art:x", Path("/assets/sprite.png"))
        assert mgr.deps["art:x"].status == "delivered"
        assert mgr.deps["art:x"].artifact == str(Path("/assets/sprite.png"))

    def test_receive_unknown_raises(self, mgr):
        with pytest.raises(ValueError, match="Unknown"):
            mgr.receive("nonexistent", Path("/x"))

    async def test_check_inbox_delivery(self, mgr, tmp_state_dir):
        mgr.deps["art:y"] = ExternalDep(id="art:y", status="pending")
        inbox_file = tmp_state_dir / "inbox" / "delivery.json"
        inbox_file.write_text(json.dumps({
            "type": "delivery",
            "dep_id": "art:y",
            "artifact_path": "/delivered/sprite.png",
        }))
        await mgr.check_inbox()
        assert mgr.deps["art:y"].status == "delivered"
        # File should be moved to processed/
        assert not inbox_file.exists()
        assert (tmp_state_dir / "inbox" / "processed" / "delivery.json").exists()

    def test_get_unmet_for_step_all_delivered(self, mgr):
        mgr.deps["art:a"] = ExternalDep(id="art:a", status="delivered")
        step = {"art_dependencies": [{"id": "art:a", "spec": {}, "placeholder": None, "blocking": True}]}
        assert mgr.get_unmet_for_step(step) == []

    def test_get_unmet_for_step_pending(self, mgr):
        mgr.deps["art:b"] = ExternalDep(id="art:b", status="pending")
        step = {"art_dependencies": [{"id": "art:b", "spec": {}, "placeholder": None, "blocking": True}]}
        unmet = mgr.get_unmet_for_step(step)
        assert len(unmet) == 1

    def test_get_assets_with_placeholder_fallback(self, mgr):
        step = {"art_dependencies": [
            {"id": "art:c", "spec": {}, "placeholder": "p.png", "blocking": False},
        ]}
        assets = mgr.get_assets_for_step(step)
        assert assets == {"art:c": "p.png"}

    def test_get_assets_delivered_overrides_placeholder(self, mgr):
        mgr.deps["art:d"] = ExternalDep(id="art:d", status="delivered", artifact="/real.png")
        step = {"art_dependencies": [
            {"id": "art:d", "spec": {}, "placeholder": "p.png", "blocking": False},
        ]}
        assets = mgr.get_assets_for_step(step)
        assert assets == {"art:d": "/real.png"}

    def test_hydrate_from_state(self, state):
        state.external_deps = [ExternalDep(id="art:pre", status="delivered", artifact="/x.png")]
        bus = EventBus()
        mgr = ExternalDepManager(
            bus=bus, inbox=Path("/tmp/in"), outbox=Path("/tmp/out"), state=state,
        )
        assert "art:pre" in mgr.deps
        assert mgr.deps["art:pre"].status == "delivered"
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_deps.py -v`
Expected: FAIL

- [ ] **Step 3: Implement ExternalDepManager**

`src/maliang/external/__init__.py`:
```python
"""External dependency management."""
```

`src/maliang/external/deps.py`:
```python
"""ExternalDepManager — track, send, receive, block, unblock external deps."""
from __future__ import annotations

import json
from pathlib import Path

from maliang.core.events import EventBus
from maliang.core.models import ExternalDep
from maliang.core.state import PipelineState


class ExternalDepManager:
    """Manages external dependencies with file-based inbox/outbox transport.
    
    State is synced to PipelineState on every mutation for crash recovery.
    """

    def __init__(self, bus: EventBus, inbox: Path, outbox: Path, state: PipelineState):
        self.bus = bus
        self.inbox = inbox
        self.outbox = outbox
        self.state = state
        self.deps: dict[str, ExternalDep] = {
            d.id: d for d in state.external_deps
        }

    def _sync_to_state(self) -> None:
        self.state.external_deps = list(self.deps.values())
        self.state.save()

    async def request(self, dep: ExternalDep) -> None:
        self.deps[dep.id] = dep
        self._sync_to_state()
        self.outbox.mkdir(parents=True, exist_ok=True)
        spec_file = self.outbox / f"{dep.id}.json"
        spec_file.write_text(json.dumps({
            "id": dep.id,
            "kind": dep.kind,
            "spec": dep.spec,
            "requested_at": self.state.updated_at,
        }))
        self.bus.emit("external.request_sent", dep_id=dep.id, spec=dep.spec)

    async def check_inbox(self) -> None:
        mutated = False
        processed_dir = self.inbox / "processed"
        processed_dir.mkdir(parents=True, exist_ok=True)

        for f in self.inbox.glob("*.json"):
            data = json.loads(f.read_text())
            msg_type = data.get("type", "")
            dep_id = data.get("dep_id", "")

            if msg_type == "delivery" and dep_id in self.deps:
                self.deps[dep_id].status = "delivered"
                self.deps[dep_id].artifact = data.get("artifact_path")
                self.bus.emit("external.delivered", dep_id=dep_id)
                mutated = True
            elif msg_type == "question":
                self.bus.emit("external.question", dep_id=dep_id, question=data.get("question", ""))
            elif msg_type == "rejection" and dep_id in self.deps:
                self.deps[dep_id].status = "rejected"
                self.bus.emit("external.rejected", dep_id=dep_id, reason=data.get("reason", ""))
                mutated = True

            f.rename(processed_dir / f.name)

        if mutated:
            self._sync_to_state()

    async def answer_question(self, dep_id: str, answer: str) -> None:
        self.outbox.mkdir(parents=True, exist_ok=True)
        reply_file = self.outbox / f"{dep_id}_reply.json"
        reply_file.write_text(json.dumps({
            "dep_id": dep_id,
            "type": "answer",
            "answer": answer,
        }))
        self.bus.emit("external.answer_sent", dep_id=dep_id, answer=answer)

    def receive(self, dep_id: str, artifact: Path) -> None:
        dep = self.deps.get(dep_id)
        if not dep:
            raise ValueError(f"Unknown dependency: {dep_id}")
        dep.status = "delivered"
        dep.artifact = str(artifact)
        self._sync_to_state()
        self.bus.emit("external.delivered", dep_id=dep_id, artifact_path=str(artifact))

    def get_unmet_for_step(self, step: dict) -> list[ExternalDep]:
        unmet = []
        for d in step.get("art_dependencies", []):
            d_id = d["id"] if isinstance(d, dict) else d.id
            dep = self.deps.get(d_id)
            if dep is None or dep.status != "delivered":
                unmet.append(dep if dep else ExternalDep(
                    id=d_id,
                    kind="art_asset",
                    spec=d.get("spec", {}) if isinstance(d, dict) else {},
                    status="pending",
                    placeholder=d.get("placeholder") if isinstance(d, dict) else None,
                    blocking=d.get("blocking", True) if isinstance(d, dict) else True,
                ))
        return unmet

    def get_assets_for_step(self, step: dict) -> dict[str, str]:
        assets = {}
        for d in step.get("art_dependencies", []):
            d_id = d["id"] if isinstance(d, dict) else d.id
            dep = self.deps.get(d_id)
            if dep and dep.status == "delivered" and dep.artifact:
                assets[d_id] = dep.artifact
            else:
                placeholder = d.get("placeholder") if isinstance(d, dict) else None
                if placeholder:
                    assets[d_id] = placeholder
        return assets
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_deps.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/external/ tests/test_deps.py
git commit -m "feat: ExternalDepManager — file-based inbox/outbox, state sync, placeholders"
```

---

## Task 14: Configuration (Pydantic Settings)

**Files:**
- Create: `src/maliang/config.py`
- Create: `tests/test_config.py`

- [ ] **Step 1: Write failing tests**

`tests/test_config.py`:
```python
"""Tests for configuration loading."""
import pytest
from pathlib import Path
from maliang.config import MaliangConfig, load_config


@pytest.fixture
def config_file(tmp_path):
    cfg = tmp_path / ".maliang" / "config.yaml"
    cfg.parent.mkdir(parents=True)
    cfg.write_text("""
agent:
  default: claude
  adapters:
    claude:
      model: claude-sonnet-4-6
engine:
  default: unity
  adapters:
    unity:
      project_path: "."
      compile_timeout: 60
pipeline:
  default_pause_policy: auto
  default_work_mode: prototype
""")
    return tmp_path


class TestConfig:
    def test_load_config(self, config_file):
        cfg = load_config(config_file / ".maliang")
        assert cfg.agent.default == "claude"
        assert cfg.engine.default == "unity"
        assert cfg.pipeline.default_pause_policy == "auto"
        assert cfg.pipeline.default_work_mode == "prototype"

    def test_load_missing_uses_defaults(self, tmp_path):
        cfg = load_config(tmp_path / ".maliang")
        assert cfg.agent.default == "claude"
        assert cfg.engine.default == "unity"
        assert cfg.pipeline.default_pause_policy == "guided"

    def test_agent_model(self, config_file):
        cfg = load_config(config_file / ".maliang")
        assert cfg.agent.adapters["claude"]["model"] == "claude-sonnet-4-6"
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_config.py -v`
Expected: FAIL

- [ ] **Step 3: Implement config**

`src/maliang/config.py`:
```python
"""Pydantic configuration for Maliang."""
from __future__ import annotations

from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field


class AgentConfig(BaseModel):
    default: str = "claude"
    adapters: dict[str, dict[str, Any]] = Field(default_factory=lambda: {
        "claude": {"model": "claude-sonnet-4-6", "max_turns_per_call": 20},
    })


class EngineConfig(BaseModel):
    default: str = "unity"
    adapters: dict[str, dict[str, Any]] = Field(default_factory=lambda: {
        "unity": {"project_path": ".", "compile_timeout": 120, "test_timeout": 180},
    })


class PipelineConfig(BaseModel):
    default_pause_policy: str = "guided"
    default_work_mode: str = "feature"


class ExternalConfig(BaseModel):
    art_pipeline: dict[str, Any] = Field(default_factory=lambda: {
        "transport": "file",
        "inbox": ".maliang/inbox",
        "outbox": ".maliang/outbox",
    })
    doc_pipeline: dict[str, Any] = Field(default_factory=lambda: {
        "watch_paths": ["docs/design/*.md"],
    })


class MaliangConfig(BaseModel):
    agent: AgentConfig = Field(default_factory=AgentConfig)
    engine: EngineConfig = Field(default_factory=EngineConfig)
    pipeline: PipelineConfig = Field(default_factory=PipelineConfig)
    external: ExternalConfig = Field(default_factory=ExternalConfig)


def load_config(maliang_dir: Path) -> MaliangConfig:
    config_path = maliang_dir / "config.yaml"
    if not config_path.exists():
        return MaliangConfig()
    from ruamel.yaml import YAML
    yaml = YAML()
    data = yaml.load(config_path)
    if data is None:
        return MaliangConfig()
    return MaliangConfig.model_validate(data)
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_config.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/config.py tests/test_config.py
git commit -m "feat: YAML configuration with pydantic defaults"
```

---

## Task 15: CLI (Typer)

**Files:**
- Create: `src/maliang/cli.py`
- Create: `tests/test_cli.py`

- [ ] **Step 1: Write failing tests**

`tests/test_cli.py`:
```python
"""Tests for CLI."""
import pytest
from typer.testing import CliRunner
from maliang.cli import app


runner = CliRunner()


class TestCLI:
    def test_version(self):
        result = runner.invoke(app, ["--version"])
        assert result.exit_code == 0
        assert "0.1.0" in result.stdout

    def test_init_creates_directory(self, tmp_path):
        result = runner.invoke(app, ["init", "--project-dir", str(tmp_path)])
        assert result.exit_code == 0
        assert (tmp_path / ".maliang" / "state").is_dir()
        assert (tmp_path / ".maliang" / "config.yaml").exists()

    def test_status_no_pipeline(self, tmp_path):
        (tmp_path / ".maliang" / "state").mkdir(parents=True)
        result = runner.invoke(app, ["status", "--project-dir", str(tmp_path)])
        assert result.exit_code == 0
        assert "no active pipeline" in result.stdout.lower() or "no pipeline" in result.stdout.lower()
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_cli.py -v`
Expected: FAIL

- [ ] **Step 3: Implement CLI**

`src/maliang/cli.py`:
```python
"""Maliang CLI — typer-based command interface."""
from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Optional

import typer
from ruamel.yaml import YAML

import maliang
from maliang.config import MaliangConfig, load_config
from maliang.core.models import PausePolicy
from maliang.core.state import PipelineState

app = typer.Typer(name="maliang", help="Agent-agnostic game dev pipeline orchestrator.")


def version_callback(value: bool):
    if value:
        typer.echo(f"maliang {maliang.__version__}")
        raise typer.Exit()


@app.callback()
def main(
    version: bool = typer.Option(False, "--version", callback=version_callback, is_eager=True),
):
    pass


@app.command()
def init(
    project_dir: Path = typer.Option(".", help="Project directory"),
    engine: str = typer.Option("unity", help="Game engine"),
    agent: str = typer.Option("claude", help="Default agent"),
):
    """Initialize maliang in a project."""
    maliang_dir = project_dir / ".maliang"
    for subdir in ["state", "plans", "designs", "inbox/processed", "outbox", "artifacts", "logs"]:
        (maliang_dir / subdir).mkdir(parents=True, exist_ok=True)

    config = MaliangConfig()
    config.engine.default = engine
    config.agent.default = agent

    yaml = YAML()
    config_path = maliang_dir / "config.yaml"
    yaml.dump(json.loads(config.model_dump_json()), config_path)

    typer.echo(f"Initialized maliang in {maliang_dir}")


@app.command()
def status(
    project_dir: Path = typer.Option(".", help="Project directory"),
):
    """Show current pipeline status."""
    maliang_dir = project_dir / ".maliang"
    state = PipelineState.load(maliang_dir / "state")
    if state is None:
        typer.echo("No active pipeline.")
        return

    typer.echo(f"Pipeline: {state.pipeline_name}")
    typer.echo(f"Phase: {state.current_phase}")
    typer.echo(f"Status: {state.status}")
    typer.echo(f"Policy: {state.pause_policy.value}")
    typer.echo(f"Completed: {', '.join(state.completed_phases) or 'none'}")

    blocked = state.get_blocked_substeps()
    if blocked:
        typer.echo(f"Blocked substeps: {[s.id for s in blocked]}")


@app.command()
def run(
    mode: str = typer.Option("feature", help="Pipeline mode"),
    input: Optional[Path] = typer.Option(None, help="Input document"),
    auto: bool = typer.Option(False, "--auto", help="Run fully automatic"),
    project_dir: Path = typer.Option(".", help="Project directory"),
    agent_name: str = typer.Option("claude", "--agent", help="Agent adapter"),
    engine_name: str = typer.Option("unity", "--engine", help="Engine adapter"),
):
    """Start a pipeline run."""
    maliang_dir = project_dir / ".maliang"
    config = load_config(maliang_dir)

    pause_policy = PausePolicy.AUTO if auto else PausePolicy(config.pipeline.default_pause_policy)
    state = PipelineState.new(mode, pause_policy)
    state.state_dir = maliang_dir / "state"
    state.save()

    typer.echo(f"Pipeline '{mode}' started (policy={pause_policy.value})")
    typer.echo(f"Agent: {agent_name}, Engine: {engine_name}")

    if input:
        typer.echo(f"Input: {input}")

    typer.echo("Use 'maliang resume' to continue after pauses.")


@app.command()
def resume(
    project_dir: Path = typer.Option(".", help="Project directory"),
):
    """Resume a paused/blocked pipeline."""
    maliang_dir = project_dir / ".maliang"
    state = PipelineState.load(maliang_dir / "state")
    if state is None:
        typer.echo("No active pipeline to resume.")
        raise typer.Exit(1)
    typer.echo(f"Resuming pipeline '{state.pipeline_name}' from phase '{state.current_phase}'")


@app.command()
def deliver(
    dep_id: str = typer.Argument(help="Dependency ID (e.g., art:slot_sprite)"),
    artifact: Path = typer.Argument(help="Path to delivered artifact"),
    project_dir: Path = typer.Option(".", help="Project directory"),
):
    """Deliver an external dependency."""
    maliang_dir = project_dir / ".maliang"
    inbox = maliang_dir / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    delivery_file = inbox / f"delivery_{dep_id.replace(':', '_')}.json"
    delivery_file.write_text(json.dumps({
        "type": "delivery",
        "dep_id": dep_id,
        "artifact_path": str(artifact.resolve()),
    }))
    typer.echo(f"Delivered {dep_id} → {artifact}")


@app.command()
def answer(
    dep_id: str = typer.Argument(help="Dependency ID"),
    text: str = typer.Argument(help="Answer text"),
    project_dir: Path = typer.Option(".", help="Project directory"),
):
    """Answer a pending question from downstream."""
    maliang_dir = project_dir / ".maliang"
    outbox = maliang_dir / "outbox"
    outbox.mkdir(parents=True, exist_ok=True)
    reply_file = outbox / f"{dep_id.replace(':', '_')}_reply.json"
    reply_file.write_text(json.dumps({
        "dep_id": dep_id,
        "type": "answer",
        "answer": text,
    }))
    typer.echo(f"Answered {dep_id}: {text}")


@app.command()
def abort(
    project_dir: Path = typer.Option(".", help="Project directory"),
):
    """Abort the current pipeline."""
    maliang_dir = project_dir / ".maliang"
    state = PipelineState.load(maliang_dir / "state")
    if state is None:
        typer.echo("No active pipeline.")
        raise typer.Exit(1)
    state.abort()
    state.save()
    typer.echo("Pipeline aborted.")
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_cli.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/cli.py tests/test_cli.py
git commit -m "feat: CLI — init, run, status, resume, deliver, answer, abort"
```

---

## Task 16: HTTP + WebSocket Server

**Files:**
- Create: `src/maliang/server.py`
- Create: `tests/test_server.py`

- [ ] **Step 1: Write failing tests**

`tests/test_server.py`:
```python
"""Tests for HTTP/WS server."""
import json
import pytest
from starlette.testclient import TestClient
from maliang.server import create_app
from maliang.core.models import PausePolicy
from maliang.core.state import PipelineState
from maliang.core.events import EventBus


@pytest.fixture
def test_app(tmp_state_dir):
    state = PipelineState.new("feature", PausePolicy.GUIDED)
    state.state_dir = tmp_state_dir / "state"
    state.current_phase = "design"
    state.save()
    bus = EventBus()
    app = create_app(state=state, bus=bus, maliang_dir=tmp_state_dir)
    return TestClient(app)


class TestServer:
    def test_get_status(self, test_app):
        resp = test_app.get("/status")
        assert resp.status_code == 200
        data = resp.json()
        assert data["pipeline_name"] == "feature"
        assert data["current_phase"] == "design"

    def test_post_decide(self, test_app):
        resp = test_app.post("/decide", json={"choice": "abort"})
        assert resp.status_code == 200

    def test_post_run(self, test_app):
        resp = test_app.post("/run", json={"mode": "prototype", "pause_policy": "auto"})
        assert resp.status_code == 200

    def test_get_deps(self, test_app):
        resp = test_app.get("/deps")
        assert resp.status_code == 200
        assert isinstance(resp.json(), list)
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_server.py -v`
Expected: FAIL

- [ ] **Step 3: Implement server**

`src/maliang/server.py`:
```python
"""HTTP + WebSocket server for UI integration."""
from __future__ import annotations

import asyncio
import json
from pathlib import Path

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route, WebSocketRoute
from starlette.websockets import WebSocket

from maliang.core.events import EventBus
from maliang.core.models import PausePolicy
from maliang.core.state import PipelineState


def create_app(
    state: PipelineState,
    bus: EventBus,
    maliang_dir: Path,
    runner=None,
) -> Starlette:
    """Create the Starlette app with routes."""

    async def get_status(request: Request) -> JSONResponse:
        fresh = PipelineState.load(state.state_dir) or state
        return JSONResponse(json.loads(fresh.model_dump_json()))

    async def get_deps(request: Request) -> JSONResponse:
        fresh = PipelineState.load(state.state_dir) or state
        return JSONResponse([json.loads(d.model_dump_json()) for d in fresh.external_deps])

    async def get_events(request: Request) -> JSONResponse:
        log_path = maliang_dir / "logs" / "events.jsonl"
        if not log_path.exists():
            return JSONResponse([])
        since = request.query_params.get("since", "")
        lines = log_path.read_text().strip().split("\n")
        events = []
        for line in lines:
            if not line:
                continue
            entry = json.loads(line)
            if since and entry.get("timestamp", "") <= since:
                continue
            events.append(entry)
        return JSONResponse(events)

    async def post_decide(request: Request) -> JSONResponse:
        body = await request.json()
        choice = body.get("choice", "")
        if runner:
            await runner.on_decision(choice)
        else:
            # Minimal: just update state directly
            if choice == "abort":
                state.abort()
                state.save()
        return JSONResponse({"ok": True, "choice": choice})

    async def post_run(request: Request) -> JSONResponse:
        body = await request.json()
        mode = body.get("mode", "feature")
        policy = PausePolicy(body.get("pause_policy", "guided"))
        new_state = PipelineState.new(mode, policy)
        new_state.state_dir = state.state_dir
        new_state.save()
        return JSONResponse({"ok": True, "mode": mode, "policy": policy.value})

    async def post_deliver(request: Request) -> JSONResponse:
        body = await request.json()
        dep_id = body.get("dep_id", "")
        artifact = body.get("artifact_path", "")
        if runner:
            await runner.on_external_delivery(dep_id, Path(artifact))
        return JSONResponse({"ok": True, "dep_id": dep_id})

    async def post_answer(request: Request) -> JSONResponse:
        body = await request.json()
        dep_id = body.get("dep_id", "")
        answer = body.get("answer", "")
        if runner:
            await runner.answer_external_question(dep_id, answer)
        return JSONResponse({"ok": True, "dep_id": dep_id})

    async def post_resume(request: Request) -> JSONResponse:
        if runner:
            await runner.run()
        return JSONResponse({"ok": True})

    async def post_abort(request: Request) -> JSONResponse:
        state.abort()
        state.save()
        return JSONResponse({"ok": True})

    async def websocket_events(ws: WebSocket) -> None:
        await ws.accept()
        queue: asyncio.Queue = asyncio.Queue()

        async def forward(event: str, data: dict):
            await queue.put({"event": event, "data": data})

        bus.on("*", forward)
        try:
            while True:
                msg = await queue.get()
                await ws.send_json(msg)
        except Exception:
            bus.off("*", forward)

    routes = [
        Route("/status", get_status, methods=["GET"]),
        Route("/deps", get_deps, methods=["GET"]),
        Route("/events", get_events, methods=["GET"]),
        Route("/decide", post_decide, methods=["POST"]),
        Route("/run", post_run, methods=["POST"]),
        Route("/deliver", post_deliver, methods=["POST"]),
        Route("/answer", post_answer, methods=["POST"]),
        Route("/resume", post_resume, methods=["POST"]),
        Route("/abort", post_abort, methods=["POST"]),
        WebSocketRoute("/ws", websocket_events),
    ]

    return Starlette(routes=routes)
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_server.py -v`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/maliang/server.py tests/test_server.py
git commit -m "feat: HTTP/WS server — REST endpoints + WebSocket event stream"
```

---

## Task 17: README + Final Integration Test

**Files:**
- Create: `README.md`
- Create: `tests/test_integration.py`

- [ ] **Step 1: Write integration test**

`tests/test_integration.py`:
```python
"""End-to-end integration test: scaffold → run prototype pipeline."""
import pytest
from unittest.mock import AsyncMock, MagicMock
from maliang.core.runner import PipelineRunner
from maliang.core.models import PausePolicy, RunOutcome, TaskResult, CompileResult
from maliang.core.state import PipelineState
from maliang.core.events import EventBus
from maliang.external.deps import ExternalDepManager


async def test_prototype_e2e(tmp_state_dir):
    """Prototype pipeline: execute → commit, fully automatic."""
    # Setup
    bus = EventBus()
    bus.enable_file_log(tmp_state_dir / "logs" / "events.jsonl")

    state = PipelineState.new("prototype", PausePolicy.AUTO)
    state.state_dir = tmp_state_dir / "state"

    agent = AsyncMock()
    agent.execute.return_value = TaskResult(
        files_modified=["game.cs"],
        decisions_made=["used singleton pattern"],
    )

    engine = AsyncMock()
    engine.name = "unity"
    engine.compile.return_value = CompileResult(ok=True)
    engine.run_tests.return_value = MagicMock(ok=True)
    engine.get_changed_files.return_value = set()
    engine.get_untracked_files.return_value = set()

    dep_mgr = ExternalDepManager(
        bus=bus, inbox=tmp_state_dir / "inbox",
        outbox=tmp_state_dir / "outbox", state=state,
    )

    runner = PipelineRunner(
        agent=agent, engine=engine, bus=bus, dep_mgr=dep_mgr, state=state,
    )

    # Write a simple plan
    plans_dir = tmp_state_dir / "plans"
    plans_dir.mkdir(exist_ok=True)
    import json
    (plans_dir / "test_plan.json").write_text(json.dumps({
        "metadata": {"feature": "test", "engine": "unity"},
        "steps": [
            {
                "id": 1,
                "title": "Implement game logic",
                "instruction": "Write the core game loop",
                "files_to_read": [],
                "files_to_edit": ["game.cs"],
                "acceptance_criteria": ["compiles"],
                "depends_on": [],
                "art_dependencies": [],
            },
        ],
    }))

    # Run
    outcome = await runner.run()

    # Verify
    assert outcome == RunOutcome.COMPLETED
    assert state.is_phase_completed("execute")
    assert state.is_phase_completed("commit")
    assert state.is_substep_completed(1)

    # Events were logged
    log_path = tmp_state_dir / "logs" / "events.jsonl"
    assert log_path.exists()
    log_content = log_path.read_text()
    assert "pipeline.started" in log_content
    assert "pipeline.completed" in log_content

    # State was persisted
    loaded = PipelineState.load(tmp_state_dir / "state")
    assert loaded is not None
    assert loaded.status == "completed"
```

- [ ] **Step 2: Run integration test**

Run: `pytest tests/test_integration.py -v`
Expected: PASS

- [ ] **Step 3: Write README**

`README.md`:
```markdown
# Maliang (马良)

Agent-agnostic game dev pipeline orchestrator. Python drives the loop, agents are stateless function calls.

## Quick Start

```bash
pip install -e ".[dev]"
maliang init --engine unity --agent claude
maliang run --mode feature --input docs/design/my_feature.md
maliang status
```

## Architecture

```
Python FSM (deterministic) → Agent Adapters (creative) → Engine Adapters (compile/test)
     ↕                              ↕                           ↕
  EventBus  ←──────────── UI / CLI / Downstream Pipelines
```

## Modes

| Mode | Pipeline |
|------|----------|
| `feature` | design → plan → execute → review → test → commit |
| `prototype` | execute → commit |
| `fix` | execute → test → commit |
| `hardening` | test → review → doc-drift → commit |

## Pause Policies

- `auto` — run to completion
- `guided` — pause at key decision points
- `manual` — pause before every phase

## Development

```bash
pip install -e ".[dev]"
pytest
ruff check src/
```
```

- [ ] **Step 4: Run full test suite**

Run: `pytest -v --tb=short`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add README.md tests/test_integration.py
git commit -m "feat: README + end-to-end integration test"
```

---

## Summary

| Task | Component | Tests | Dependencies |
|------|-----------|-------|--------------|
| 1 | Project scaffold | conftest | — |
| 2 | Data models (pydantic) | 12 tests | — |
| 3 | EventBus | 5 tests | — |
| 4 | Pipeline definitions | 6 tests | models |
| 5 | PlanValidator | 6 tests | models |
| 6 | PipelineState | 12 tests | models |
| 7 | StepExecutor | 7 tests | models, events, state |
| 8 | PipelineRunner | 5 tests | executor, pipeline, state, events |
| 9 | AgentAdapter protocol | 2 tests | models |
| 10 | ClaudeAdapter | 2 tests | agent base, prompts |
| 11 | EngineAdapter protocol | 1 test | models |
| 12 | UnityAdapter | 7 tests | engine base |
| 13 | ExternalDepManager | 10 tests | models, events, state |
| 14 | Configuration | 3 tests | — |
| 15 | CLI | 3 tests | config, state |
| 16 | HTTP/WS server | 4 tests | state, events |
| 17 | README + integration | 1 e2e test | all |

**Total: 17 tasks, 86 tests, 16 source files.**

Build order: Tasks 1-6 have no cross-dependencies and can be parallelized. Tasks 7-8 depend on 2-6. Tasks 9-13 can be parallelized after 2. Tasks 14-17 are final assembly.
