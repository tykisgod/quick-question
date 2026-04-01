# Consumer Rollout

This checklist is for Unity projects that **consume** `qq` / `tykit`.

Use it for:

- `project_pirate_demo`
- internal sample projects
- external user projects

Do **not** treat these projects as local `tykit` development workspaces.

## Core Rule

Consumer projects should use the same install path as real users:

- normal git/package dependency for `tykit`
- normal `qq` install flow
- no local `file:` package override
- no symlinked `Packages/com.tyk.tykit`

Local package linking is only for package development and can hide real integration issues.

## Release Flow

1. Land the `qq` / `tykit` changes in this repo.
2. Let the repo CI publish the new `tykit` revision/version it manages.
3. Update the consumer project to that published revision.
4. Validate from the consumer project exactly like an external user would.

## Consumer Project Checklist

### Package State

- `Packages/manifest.json` points `com.tyk.tykit` at the published git revision or package source
- `Packages/packages-lock.json` is updated by Unity/package resolution
- `Packages/com.tyk.tykit` does not exist as an embedded local package unless you are explicitly testing embedded-package support

### qq State

- `qq` is installed through the normal project setup flow
- project scripts come from the normal `qq` install/update path
- the built-in project-local MCP bridge comes from the normal `qq` install/update path
- no ad hoc local script copies are required for the feature to work

### MCP State

- `.mcp.json` points at the consumer project's own `scripts/qq_mcp.py`
- the MCP server is launched with the consumer project's path
- the bridge sees the published `tykit` package, not a local dev checkout

Example:

```bash
python3 scripts/qq_mcp.py --project .
```

## Smoke Test

Run these checks from the consumer project:

1. Open the Unity Editor and wait for domain reload/initial import to settle.
2. Confirm `Temp/tykit.json` exists.
3. Run one compile check.
4. Run one test check.
5. Run `./scripts/qq-doctor.sh` and confirm it prefers qq direct first, then the built-in qq MCP bridge.
6. Run one query tool such as `unity_health` or `unity_query status`.
7. If using an MCP client, confirm `tools/list` and one `tools/call` succeed.

Recommended minimum verification:

- compile passes
- one targeted test run passes
- `qq-doctor.sh` reports the built-in bridge as project-local
- `describe-commands` returns metadata
- MCP health reports `metadata_available: true`

## Demo Project Policy

For demo/sample projects, prefer realism over convenience.

That means:

- test the published dependency path
- test the normal `qq` install path
- do not keep local package overrides around after package development verification

If a package change must be validated before publish, do that in a temporary local-link session, then restore the demo project back to the published dependency before calling the work done.

## Rollback

If a consumer rollout fails:

1. Pin the previous known-good `tykit` revision in `Packages/manifest.json`.
2. Let Unity re-resolve `Packages/packages-lock.json`.
3. Re-run the same smoke test.

This keeps rollback behavior identical to what external users would do.
