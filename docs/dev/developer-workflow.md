# Developer Workflow

This is the recommended development workflow for `quick-question`.

## The Rule

Use:

1. **worktrees** to isolate tasks
2. **Docker** for `qq-core` / repo development
3. the **host machine** for Unity / `tykit` / real-project validation

Do not try to force local Unity Editor work into Docker.

This rule is also codified in the repository root [`AGENTS.md`](../../AGENTS.md) so coding agents see it before they start changing the repo.

## 1. Create a Worktree Per Task

Create a dedicated worktree for each task:

```bash
git worktree add -b feat/<topic> ../quick-question-<topic> main
```

Why:

- task isolation
- no branch checkout churn in one directory
- cleaner AI-driven parallel work
- safer experiments

## 2. Use Docker for Repo Development

When changing repository code such as:

- `scripts/*.sh`
- `scripts/*.py`
- `README`
- `docs`
- `install.sh`
- `test.sh`
- capability / doctor / policy / runtime core

use the dev container image.

### Build the image

```bash
./scripts/docker-dev.sh build
```

### Open a shell in the dev container

```bash
./scripts/docker-dev.sh shell
```

### Run the standard container-side validation

```bash
./scripts/docker-dev.sh test
```

The helper script automatically handles Git worktree mount layout. This matters because a worktree's `.git` file points back into the main repository's `.git/worktrees/...` directory.

If you bind-mount only the worktree folder, Git commands inside the container can fail.

## 3. Use the Host Machine for Unity Validation

When changing:

- `tykit`
- Unity provider behavior
- compile/test routing
- real Unity install flow
- Editor integration behavior

validate on the host machine, not in Docker.

Typical host-side checks:

```bash
./install.sh /path/to/unity-project
/path/to/unity-project/scripts/unity-compile-smart.sh
python3 /path/to/unity-project/scripts/qq-project-state.py --project /path/to/unity-project --pretty
```

## Default Flow

For most repository tasks:

1. create a worktree
2. run `./scripts/docker-dev.sh build` once
3. work inside `./scripts/docker-dev.sh shell`
4. run `./scripts/docker-dev.sh test` before committing
5. only if Unity-specific code changed, switch back to host-side validation

## Parallel Agent Best Practice

When one person is driving multiple agents across multiple features, follow this rule:

- **one agent = one worktree**
- **one agent = optionally one container session**
- **many agents may share one Docker image**
- **zero agents may share one worktree**

This is the important split:

- **worktree** isolation protects files, git status, and branch state
- **Docker** isolation protects shell, process, and tool environment

Docker does **not** prevent two agents from modifying the same worktree if they mount the same directory. If two containers point at the same worktree, they are still editing the same files.

Recommended flow for one person controlling multiple agents:

1. create one worktree per feature
2. run `./scripts/docker-dev.sh build` once
3. let each agent work inside its own worktree
4. if you want repo-dev isolation, give each agent its own `./scripts/docker-dev.sh shell` session
5. run `./scripts/docker-dev.sh test` inside each worktree before merge-back
6. if a feature touches Unity / `tykit`, do the final verification on the host machine for that worktree

Example:

```bash
git worktree add -b feat/runtime-evaluator ../quick-question-runtime-evaluator main
git worktree add -b feat/provider-docs ../quick-question-provider-docs main

cd ../quick-question-runtime-evaluator
./scripts/docker-dev.sh build
./scripts/docker-dev.sh shell

cd ../quick-question-provider-docs
./scripts/docker-dev.sh shell
```

In that setup:

- both agents reuse the same image
- each agent has its own shell/process state
- each agent has its own filesystem and git state
- neither agent can accidentally corrupt the other's worktree unless you explicitly point them at the same path

## Why This Split Exists

Docker is useful for:

- repeatable repo development
- fresh-machine setup
- future CI alignment

The host machine is still required for:

- local Unity Editor control
- `tykit`
- real compile/test behavior in an installed Unity project

This split keeps the repo workflow clean without damaging the local Unity fast path.
