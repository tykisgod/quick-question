# Recording in Unity

## Contents
1. Editor recorder: Play mode, no code change (`eval_file`)
2. Editor preview scenes outside Play mode
3. Build reel: dev-only component in a player / development build
4. Camera rules
5. Pitfalls
6. Screenshot sets

All commands use the official Unity CLI. See [`shared/unity-cli-reference.md`](../../../shared/unity-cli-reference.md) for the call shape and for reading replies: `success` must be true, `errors` empty, and `data.result` holds the answer.

## 1. Editor recorder: Play mode, no code change

Use it for a quick look at any branch or commit. Nothing is added to the project.

1. Put the editor in the scene and state you need: `open_scene`, any project menu that selects a test preset, then `editor_play`. Poll `editor_status` until `data.result.playMode` is `playing`. If the game has a boot phase, poll a small `eval` query until it reports ready, e.g. a lifetime / phase flag.
2. Copy [`../templates/unity_editor_recorder.cs`](../templates/unity_editor_recorder.cs) outside `Assets/`, fill in `OUT` and the shot list, then run it:
   ```bash
   unity command --project-path "$PWD" --json --no-banner eval_file -- --file "<absolute path>" --timeout 60000
   ```
   It returns at once with `"recording N shots into …"`. Recording happens in an `EditorApplication.update` callback, one capture per game frame.
3. Wait for `<OUT>/done.txt`. `error.txt` holds the exception. Then `editor_stop`, and continue with `qq-frames-to-mp4.py --batch`.

Rules for `eval_file` code. The CLI compiles it as a method body:

- **Code shape:** no `using` lines, no class declarations, fully qualified type names (`UnityEngine.Vector3`), and the last statement must be `return …;`. A trailing expression without `return` fails with "; expected". Local functions, lambdas and tuples work. The callback's closures stay alive after the eval returns.
- **Never wait inside the eval.** It runs synchronously on the main thread, and a long eval wedges the editor's whole CLI channel. Install, return, poll a file.
- **Errors are compile errors:** compile errors come back as `COMMAND_FAILED` with line and column of your file.
- **Reflection is acceptable here**, because this is developer tooling. Use it to flip private fields of showcase or debug components; the template has the helper.

What the template already does:

- **Locks game time:** `Time.captureFramerate = FPS`.
- **One capture per game frame:** deduplicates on `Time.frameCount`.
- **Renders without the overlay UI:** sets the camera rect to the full texture for the render (a viewport rect renders into part of it), renders `Camera.main` into a RenderTexture, reads back, saves JPG, then restores the camera pose, FOV and rect. Screen Space Overlay UI does not go through the camera, so captures have no HUD.
- **Writes the outputs:** `clips.json` with per-clip readbacks and `done.txt`.

If frames stop advancing while the editor window is in the background, set `UnityEngine.Application.runInBackground = true` in a small `eval` before recording. The Player setting decides whether Play mode keeps ticking unfocused.

## 2. Editor preview scenes outside Play mode

Use this to show an animation or rig before it runs in game, in a scratch scene that is not saved.

- **Stepping:** advance in `EditorApplication.update` with a fixed dt, and render each camera with `Camera.Render()` into a RenderTexture.
- **Skinned meshes:** they do not re-skin on a manual render in edit mode. Set `SkinnedMeshRenderer.forceMatrixRecalculationPerRender = true` on every one, or characters stay in bind pose.
- **Anti-aliasing:** MSAA on a RenderTexture is not reliable under URP with manual renders. Supersample instead: render at 2× (3840×2160) and downscale to 1080p. Jagged 960×540 captures read as "mosaic" once scaled up.
- **Timing:** previews often fake game timing (reload progress, animation speed), so the preview does not prove the in-game look. Say so on the page, and record the real game for acceptance.

## 3. Build reel: dev-only component in a player build

Use this when the project judges visual effects only in a development build. Unity Recorder works only in the editor, so it cannot do this.

- **Component:** a MonoBehaviour under `#if UNITY_EDITOR || DEVELOPMENT_BUILD`.
- **Switch:** started by a command-line switch `-<name>Reel <dir> [-<name>Reel-quit]`. If the game has a start screen, a boot gate or an "unattended arguments" list, register the switch there; otherwise the build sits at the menu until timeout.
- **Run order:**
  1. Wait until the world is ready, plus a few seconds for spawns to settle.
  2. Set `Time.captureFramerate`.
  3. For each clip, set things up, then capture in `LateUpdate`: pose the camera first, then render to a RenderTexture and save.
  4. Write `clips.json`.
  5. `Application.Quit()` when `-quit` is given.
- **Launch:** windowed, at a fixed resolution, behind other windows so it doesn't steal focus. Restore any screen settings the launch wrote. Copy the player log next to the frames.
- **Reuse:** one switch per feature quickly duplicates. When the project already has a reel component, add a clip to it instead of writing a new harness.

## 4. Camera rules

- **Default framing first:** start from the player's default camera (distance, pitch, FOV); that is what the user judges. Add close-ups for small effects, at about 1–2 body heights from the subject.
- **Moving platforms (ships, vehicles):** keep the camera pose in the platform's local space and convert with `TransformPoint` every frame, or the clip shakes against the platform. Smooth position only; aim the rotation at the target every frame.
- **Following a character:** stand on the inside of the platform and look outward from above, or railings and walls cut the character off.
- **Hand control back:** stop the game's camera controller while posing (`enabled = false`) and re-enable it at the end.

## 5. Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Video stretched to 1088 rows, slightly blurred | imageio `write_frames` pads to multiples of 16 | Use `qq-frames-to-mp4.py`, which hands ffmpeg exact even sizes |
| UI timers or tweens run too fast or slow in the clip | `Time.unscaledTime` ignores `captureFramerate` | Note it, or drive those from scaled time for the recording |
| Clip "stops a frame, jumps a frame" | A system throttled on real time is mixed with fixed game-time steps | Measure frame-to-frame differences before blaming the feature; the jump can also be a real bug |
| Black or pink frames at the start | Shaders still compiling asynchronously | Wait until `ShaderUtil.anythingCompiling` is false, and skip warm-up frames |
| Objects popping between frames | LOD cross-fade | Disable cross-fade, or keep the camera distance constant per clip |
| HUD or debug panel in the frames | `ScreenCapture` captures the final screen | Render the camera to a RenderTexture, or hide canvases first |
| Nothing renders in a CI or batch editor | `-batchmode` has no graphics device | Record in an editor or player with a GPU |
| Recording stalls, editor killed | Heavy jobs (full test runs, builds) running at the same time | Record alone; queue behind heavy jobs |
| Recorded scene state looks right but nothing happens | The trigger has no effect in this setup | Read state back after a dry run (SKILL.md step 3) |

## 6. Screenshot sets

- **Mechanism:** same as video, one frame per camera pose. Wait a frame or two after posing, and wait for shaders and streaming to finish.
- **One-off looks:** `capture_game_view -- --save_path Screenshots/x.png` (add `--source screen` to include overlay UI; Play mode only) or `screenshot -- --view game`. For those two, read `data.result.success`.
- **Lighting and sun:** a midday sun straight overhead flattens everything. Pick a time of day, and record it on the page.
- **Comparison pairs:** same pose, same time, same weather, one change.
- **Metadata:** write each shot's camera, game clock and weather into the manifest `fact`, so odd-looking frames can be checked against data before anyone acts on them.
