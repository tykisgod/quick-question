# Remove Context Capsule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the entire Context Capsule system — a dead feature that generates files nobody reads.

**Architecture:** Delete `qq-context-capsule.py`, strip capsule logic from `qq-codex-exec.py` / `qq-runtime.sh` / `session-cleanup.sh` / `qq-run-record.py`, remove capsule config from `qq_internal_config.py`, remove capsule tests from `test.sh`, remove capsule entry from `qq_internal_install.py`.

**Tech Stack:** Python, Bash, qq plugin framework

**Repo root:** `C:/Users/ASUS/.claude/plugins/marketplaces/quick-question-marketplace`

---

### Task 1: Delete `qq-context-capsule.py` and its docs

**Files:**
- Delete: `scripts/qq-context-capsule.py`
- Delete: `docs/dev/context-capsule.md`

- [ ] **Step 1: Delete the files**

```bash
cd "C:/Users/ASUS/.claude/plugins/marketplaces/quick-question-marketplace"
rm scripts/qq-context-capsule.py
rm docs/dev/context-capsule.md
```

- [ ] **Step 2: Remove from install file list**

In `scripts/qq_internal_install.py`, delete line 25:
```python
            "scripts/qq-context-capsule.py",
```

- [ ] **Step 3: Commit**

```bash
git add -A scripts/qq-context-capsule.py docs/dev/context-capsule.md scripts/qq_internal_install.py
git commit -m "chore: delete qq-context-capsule.py and its design doc"
```

---

### Task 2: Strip capsule logic from `qq-runtime.sh`

**Files:**
- Modify: `scripts/qq-runtime.sh`

- [ ] **Step 1: Remove capsule trigger from `qq_run_record_finish()`**

In `scripts/qq-runtime.sh`, remove lines 63-67 (the `case` block in `qq_run_record_finish`):

```bash
    case "$status" in
        failed|blocked)
            qq_context_capsule_maybe_build "after_blocker" >/dev/null
            ;;
    esac
```

- [ ] **Step 2: Remove four capsule helper functions**

Delete `qq_context_capsule_build()` (lines 83-88), `qq_context_capsule_maybe_build()` (lines 90-95), `qq_context_capsule_status()` (lines 97-100), `qq_context_capsule_prompt()` (lines 102-106).

- [ ] **Step 3: Commit**

```bash
git add scripts/qq-runtime.sh
git commit -m "chore: remove capsule functions from qq-runtime.sh"
```

---

### Task 3: Strip capsule from `session-cleanup.sh`

**Files:**
- Modify: `scripts/hooks/session-cleanup.sh`

- [ ] **Step 1: Remove capsule trigger**

Delete this line from `scripts/hooks/session-cleanup.sh`:
```bash
qq_context_capsule_maybe_build "pre_clear" >/dev/null
```

The file should become:
```bash
#!/usr/bin/env bash
# Stop hook: clean up session temp files
source "$(cd "$(dirname "$0")/.." && pwd)/platform/detect.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/qq-runtime.sh"

rm -f "$QQ_TEMP_DIR/review-gate-$PPID"
run_json=$(qq_run_record_start "review_gate" "session-cleanup" "local" "hook" "Review gate cleanup")
run_id=$(printf '%s' "$run_json" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
qq_run_record_finish "$run_id" "cleared" "" "Session cleanup removed review gate" >/dev/null
qq_runtime_prune
```

- [ ] **Step 2: Commit**

```bash
git add scripts/hooks/session-cleanup.sh
git commit -m "chore: remove capsule trigger from session-cleanup hook"
```

---

### Task 4: Strip capsule from `qq-run-record.py`

**Files:**
- Modify: `scripts/qq-run-record.py`

- [ ] **Step 1: Remove `prune_context_capsules()` function**

Delete the entire `prune_context_capsules()` function (added earlier in this session).

- [ ] **Step 2: Remove capsule from `prune_runtime()`**

Remove the `max_capsule_files` parameter, the `effective_max_capsule_files` line, the `prune_context_capsules()` call, and the `capsules_removed`/`capsules_removed_count`/`max_capsule_files` entries from the result dict.

- [ ] **Step 3: Remove `--max-capsule-files` from CLI**

In `command_prune()`, remove `max_capsule_files=args.max_capsule_files`. In `build_parser()`, remove the `--max-capsule-files` argument.

- [ ] **Step 4: Commit**

```bash
git add scripts/qq-run-record.py
git commit -m "chore: remove capsule pruning from qq-run-record.py"
```

---

### Task 5: Strip capsule from `qq-codex-exec.py`

**Files:**
- Modify: `scripts/qq-codex-exec.py`

- [ ] **Step 1: Remove `load_context_capsule_consume()` function** (lines 56-94)

- [ ] **Step 2: Remove `merge_resume_prompt()` function** (lines 222-230)

- [ ] **Step 3: Simplify `build_exec_command()`**

Remove parameters `resume`, `resume_refresh`, `resume_note`, `no_resume`. Remove the `resume_payload` / `resume_prompt` block (lines 315-322). Replace `command.extend(merge_resume_prompt(passthrough, resume_prompt))` with `command.extend(passthrough)`. Remove all `resume*` keys from the payload dict.

- [ ] **Step 4: Remove capsule CLI arguments from `build_parser()`**

Remove `--resume`, `--resume-refresh`, `--resume-note`, `--no-resume` arguments.

- [ ] **Step 5: Simplify `main()`**

Remove `resume`/`resume_refresh`/`resume_note`/`no_resume` from the `build_exec_command()` call.

- [ ] **Step 6: Verify dry-run**

```bash
cd "C:/Users/ASUS/.claude/plugins/marketplaces/quick-question-marketplace/scripts"
python qq-codex-exec.py --project /tmp --dry-run --pretty "test prompt"
```

Expected: JSON output without any `resume*` fields.

- [ ] **Step 7: Commit**

```bash
git add scripts/qq-codex-exec.py
git commit -m "chore: remove capsule consumption from qq-codex-exec.py"
```

---

### Task 6: Clean capsule config from `qq_internal_config.py`

**Files:**
- Modify: `scripts/qq_internal_config.py`

- [ ] **Step 1: Remove capsule constants**

Delete `VALID_CONTEXT_CAPSULE_TRIGGERS`, `DEFAULT_CONTEXT_CAPSULE_TRIGGERS`, `DEFAULT_CONTEXT_CAPSULE`.

- [ ] **Step 2: Remove capsule functions**

Delete `normalize_context_capsule_payload()` and `merge_context_capsule_payload()`.

- [ ] **Step 3: Remove capsule from config resolution**

In every function that processes `context_capsule` (grep for `context_capsule` in the file), remove the capsule-specific handling. The config resolution should just ignore `context_capsule:` in yaml.

- [ ] **Step 4: Commit**

```bash
git add scripts/qq_internal_config.py
git commit -m "chore: remove capsule config from qq_internal_config.py"
```

---

### Task 7: Remove capsule references from docs

**Files:**
- Modify: `docs/dev/agent-integration.md`

- [ ] **Step 1: Remove capsule consume API references**

In `docs/dev/agent-integration.md`, remove the paragraph about capsule auto-injection (line 47) and the `consume` API example (lines 61-63). Update the `qq-codex-exec.py` description to just mention worktree/sandbox/MCP isolation without capsule.

- [ ] **Step 2: Commit**

```bash
git add docs/dev/agent-integration.md
git commit -m "docs: remove capsule references from agent-integration.md"
```

---

### Task 8: Remove capsule tests from `test.sh`

**Files:**
- Modify: `test.sh`

- [ ] **Step 1: Remove capsule test blocks**

Remove all test blocks that test capsule functionality. Key sections (by line numbers and test names):
- Lines ~297-332: "context capsule builds a thin resume handoff from runtime state"
- Lines ~335-349: "context capsule can render a standard resume consumer prompt"
- Lines ~352-370: "context capsule exposes a host-neutral consume interface"
- Lines ~373-389: "context capsule consume interface supports per-request opt-out for any host"
- Lines ~392-417: "strict trust level disables automatic context capsule consumption"
- Lines ~421-526: context capsule auto mode / disabled / after blocker / session cleanup tests
- Lines ~1377-1381: worktree capsule assertion
- Lines ~1769: worktree capsule assertion
- Lines ~1829: codex-exec capsule resume reason assertion
- Lines ~1847-1892: codex-exec capsule consume/opt-out tests
- Line ~4050: config validation `context_capsule:` reference

Also remove capsule temp file declarations (`CAPSULE_BUILD_JSON`, `CAPSULE_STATUS_JSON`) and cleanup lines.

- [ ] **Step 2: Commit**

```bash
git add test.sh
git commit -m "test: remove all capsule-related test cases"
```

---

### Task 9: Sync to plugin cache and verify

- [ ] **Step 1: Copy modified files to cache**

```bash
cp -r "C:/Users/ASUS/.claude/plugins/marketplaces/quick-question-marketplace/scripts/" \
      "C:/Users/ASUS/.claude/plugins/cache/quick-question-marketplace/qq/1.9.3/scripts/"
cp -r "C:/Users/ASUS/.claude/plugins/marketplaces/quick-question-marketplace/hooks/" \
      "C:/Users/ASUS/.claude/plugins/cache/quick-question-marketplace/qq/1.9.3/hooks/"
```

- [ ] **Step 2: Verify session-cleanup runs without error**

```bash
cd "E:/dpp_new/new_2/project_pirate_demo"
PROJECT_DIR="E:/dpp_new/new_2/project_pirate_demo" bash "C:/Users/ASUS/.claude/plugins/cache/quick-question-marketplace/qq/1.9.3/scripts/hooks/session-cleanup.sh"
```

- [ ] **Step 3: Verify no new capsule files generated**

```bash
ls "E:/dpp_new/new_2/project_pirate_demo/.qq/telemetry/context-capsules/"
# Should show only the 10 remaining files, no new ones
```

- [ ] **Step 4: Commit final state**

```bash
git add -A
git commit -m "chore: remove Context Capsule system — dead feature cleanup"
```
