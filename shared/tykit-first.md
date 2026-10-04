# Tykit-First Mindset → moved to [`unity-live-state.md`](./unity-live-state.md)

The "query the live Editor before reading code" rule is now channel-agnostic: [`unity-live-state.md`](./unity-live-state.md) says *when* to query the Editor, how to tell which channel a project uses (official Unity CLI when `Library/Pipeline/.unity-pipeline-port` exists — never print that file, it holds an eval token — and tykit when `Temp/tykit.json` does), and gives the commands for both.
Command maps: [`unity-cli-reference.md`](./unity-cli-reference.md) (official Unity CLI) · [`tykit-reference.md`](./tykit-reference.md) (tykit only).
