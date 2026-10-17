# Recording in Unreal Engine 5

- **Cinematics (Level Sequences):** use Movie Render Queue. It renders a sequence with a fixed frame rate to an image sequence, and runs from the command line:
  ```bash
  UnrealEditor-Cmd.exe <Project.uproject> <Map> -game -MoviePipelineConfig="/Game/Path/QueueConfig" -windowed -Unattended -Log
  ```
  Choose PNG or JPG output, one folder per clip. This records cinematics, not live gameplay.
- **Live gameplay:** lock the step so slow frames don't drop.
  - `-benchmark -fps=30` (stripped from Shipping builds) or `-deterministic` (fixed time step plus fixed seed).
  - Save frames from a dev-only actor or subsystem started by a command-line switch: `FScreenshotRequest::RequestScreenshot(Path, false, false)` each frame, or read back a `USceneCaptureComponent2D` render target, which has no UI.
  - The actor writes `clips.json` (`[{"name", "title", "fps", "state"}]`, plus `"seen": false` for a clip that waited for an effect that never came, so `--batch` names it) and quits with `FGenericPlatformMisc::RequestExit(false)`.
- **Stills:** `HighResShot 1920x1080` from the console. Screenshot Comparison / Functional Screenshot Tests disable noisy features (AA, motion blur, auto exposure) for stable before/after pairs.

Then run `qq-frames-to-mp4.py --batch <out>` and continue with SKILL.md step 6.

Sources: https://dev.epicgames.com/documentation/unreal-engine/movie-render-queue-in-runtime-in-unreal-engine, https://unreal-garden.com/docs/command-line-arguments/, https://dev.epicgames.com/documentation/en-us/unreal-engine/screenshot-comparison-tool-in-unreal-engine
