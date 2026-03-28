Comment 1 — performance + latency

Performance hit is basically zero in the normal case. The hook only triggers on .cs files — edit a shader, a ScriptableObject, whatever, nothing happens. When it does trigger, there are three tiers:

- tykit mode (the in-process HTTP server): ~1-2s, fires off a compile request over localhost. Editor doesn't even blink. This is the default if you have the package installed.
- osascript fallback: briefly pokes the Editor to trigger refresh. 5-15s depending on project size. Only if tykit isn't available.
- Batch mode: the slow one (~30-60s), but this only kicks in when the Editor isn't running at all.

So in practice you write code, it compiles in the background, you get errors back in your terminal. Pretty seamless.

For cross-model review — the Codex call itself takes a few minutes, but it runs in the background so you're not sitting there waiting. You can keep reading code, planning, whatever. The verification subagents also run in parallel. Most reviews wrap up in 1-2 rounds. It's not instant, but it's not blocking your workflow either.


---


Comment 2 — scene hierarchy, prefabs, Windows

Actually yeah, it already handles a lot of that. The tykit package runs an HTTP server inside the Editor with 40+ commands. Quick rundown:

- Hierarchy: full tree dump, search by name/tag/component, inspect any object's components and properties, create/destroy/duplicate/reparent GameObjects
- Prefabs: instantiate from asset path (with position, parent, etc.), save scene objects as new prefabs
- Assets: list with filters (e.g. t:Scene, t:Material), create materials, refresh/reimport
- Components: add/remove, get/set arbitrary properties on any component
- It also does UI creation, animations, play/stop/pause, screenshots, simulated input, and can invoke any Unity menu item

So Claude can basically build and manipulate scenes entirely from the terminal.

Windows: not officially supported yet. The tykit server itself is pure C# so it works anywhere Unity runs. The macOS-specific stuff is really just the fallback compilation path (osascript, lsof/pgrep for process detection). With tykit installed those fallbacks aren't even needed, so a Windows port is mostly about replacing the shell-level process detection. Architecturally nothing prevents it, just hasn't been done yet.


---


Comment 3 — close/reopen misunderstanding

Ha no, that would be painful. It's actually the opposite — the whole design is to avoid restarting Unity.

The preferred path (tykit) is an HTTP server running inside the already-open Editor. It just sends a compile request over localhost — no restart, no focus steal, takes about a second. The Editor stays right where it is.

There's an osascript fallback that pokes the Editor to trigger refresh (still no restart), and batch mode only fires when the Editor isn't running at all. The script auto-detects which option is available and picks the fastest one.

So with tykit installed: write code in terminal, compile happens in the background, errors show up in your session. Unity doesn't move.
