# Containerization

`quick-question` should support containers, but only in the right layer.

## Position

Containerization is a support path for:

- repository development
- Codespaces / Dev Containers
- future CI and headless validation

Containerization is **not** the default runtime for local Unity work.

The local fast path remains:

- qq direct scripts
- `tykit`
- `tykit_mcp`

This keeps the core product optimized for the Unity developer loop while leaving room for CI-safe and remote-friendly providers later.

## What Exists Now

This repository now includes a minimal Dev Container:

- [`.devcontainer/devcontainer.json`](../../.devcontainer/devcontainer.json)
- [`.devcontainer/Dockerfile`](../../.devcontainer/Dockerfile)
- [`.devcontainer/postCreate.sh`](../../.devcontainer/postCreate.sh)
- [`scripts/docker-dev.sh`](../../scripts/docker-dev.sh)

The devcontainer is intended for contributors working on `quick-question` itself. It installs the tools needed to run the repository checks and helper CLIs:

- `bash`
- `git`
- `python3`
- `jq`
- `curl`
- `shellcheck`

## What This Does Not Do

This container does **not**:

- run Unity Editor inside the container
- replace `tykit` for local editor control
- change the default provider order for local users
- make Docker mandatory for `quick-question`

That boundary is intentional.

## Recommended Usage

Use the devcontainer when you want:

- a clean and repeatable environment for repo development
- Codespaces support
- a consistent contributor setup across macOS, Windows, and Linux hosts

Recommended entrypoint:

```bash
./scripts/docker-dev.sh build
./scripts/docker-dev.sh shell
```

or run the full repository-side validation:

```bash
./scripts/docker-dev.sh test
```

See [Developer Workflow](developer-workflow.md) for the full split between Docker-based repo development and host-side Unity validation.
