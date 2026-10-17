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

1. Put the editor in the scene and state you need: `open_scene`, any project menu that selects a test preset, then `editor_play`. Poll `editor_status` until `data.result.playMode` is `playing`. Then poll a tiny `eval` (`return 1;`) until it answers: right after entering Play the main thread is still busy, and the first eval can time out at 5000 ms even though `playMode` already says `playing`. If the game has a boot phase, poll an `eval` query until it reports ready, e.g. a lifetime / phase flag.
2. Copy [`../templates/unity_editor_recorder.cs`](../templates/unity_editor_recorder.cs) outside `Assets/`, fill in `OUT` and the shot list, then run it:
   ```bash
   unity command --project-path "$PWD" --json --no-banner eval_file -- --file "<absolute path>" --timeout 60000
   ```
   It returns at once with `"recording N shots into …"`. Recording happens in an `EditorApplication.update` callback, one capture per game frame.
3. Wait for `<OUT>/done.txt`. `error.txt` holds the exception. Continue with `qq-frames-to-mp4.py --batch` and the contact sheets, **staying in Play mode**: a retake then needs no re-entry and no re-setup. `editor_stop` only after the self-check has passed.

Rules for `eval_file` code. The CLI compiles it as a method body:

- **Code shape:** no `using` lines, no class declarations, fully qualified type names (`UnityEngine.Vector3`), and the last statement must be `return …;`. A trailing expression without `return` fails with "; expected". Local functions, lambdas and tuples work. The callback's closures stay alive after the eval returns.
- **Never wait inside the eval.** It runs synchronously on the main thread, and a long eval wedges the editor's whole CLI channel. Install, return, poll a file.
- **Errors are compile errors:** compile errors come back as `COMMAND_FAILED` with line and column of your file.
- **Reflection is acceptable here**, because this is developer tooling. Use it to flip private fields of showcase or debug components; the template has the helper.

What the template already does:

- **Locks game time:** `Time.captureFramerate = FPS`.
- **One capture per game frame:** deduplicates on `Time.frameCount`.
- **Renders without the overlay UI:** sets the camera rect to the full texture for the render (a viewport rect renders into part of it), renders `Camera.main` into a RenderTexture, reads back and saves JPG. Screen Space Overlay UI does not go through the camera, so captures have no HUD.
- **Camera restore:** with `RESTORE_CAMERA = true` it puts the camera back after each capture, so the game's camera controller keeps working. Systems that follow the camera then see the restored pose, not the rendered one (see §5). Disable the controller and set `RESTORE_CAMERA = false` when that matters.
- **Stills:** a shot marked `still` runs its frames and saves only the last one, as `stills/<name>.jpg`. `--batch` puts it on the page as an image.
- **Shots that run until the effect:** each shot has a minimum and maximum length and an optional `Done(f)`. The first time `Done` is true is kept, and the shot ends there or at the minimum, whichever comes later; at the maximum it ends anyway, and if `Done` was never true `clips.json` gets `"seen": false`. The third example shot shows the shape: first trigger, a stronger one on a deadline, a caption at the second it happened, a few seconds of aftermath.
- **Occlusion-aware cameras:** `ClearEye(target, prefer, dist, height, self)` tries directions turning away from `prefer` at three heights and returns the first viewpoint that is not inside any bounds in `occluders` and whose line to the target misses them and every collider (a hit near the target and below it counts as its ground). `Fixed` picks one at `f == 0` and holds it; `Follow` re-checks three times a second and pans to a clear offset when blocked. Fill `occluders` with `AddOccluders(root, pick)`: buildings and props, including the ones next to the subject (a stack of crates in front of the fish baskets). Pass the subject's root as `self` when it has renderers or colliders of its own (a character, the prop being filmed), so they don't count as blocking. `Up(p)` is world up; on a round world or a tilted platform replace it with the local up (`Orbit` ignores it).
- **Safety:** it refuses to start while another recording runs in the same Editor, and it refuses to wipe an `OUT` that holds anything other than an earlier recording (with `ONLY` set, see Retakes).
- **Writes the outputs:** `clips.json` with per-clip readbacks, the `seen` flag and `done.txt`.
- **Retakes:** set `var ONLY = new[] { "<shot name>" };` and `OUT = <topic>/rec-retake` in a copy of your script, run it, `--batch` that folder, and point that item of the first manifest at the retake's mp4 (`../../rec-retake/mp4/<shot>.mp4`). With `ONLY` set, the template refuses any `OUT` that holds anything unless its name ends in `-retake`, encoded or not, so a mistyped `OUT` can't wipe the first take. A second retake round wipes the first one's folder: record it into a new one (`rec2-retake`) when the page still points at the first.
- **Helpers:** `Call` / `SetF` / `GetF` for methods and private fields of showcase or debug components; `Cap(clip, frame, text)` for per-frame captions (`timeline.jsonl`, burned in by `--batch`).

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

- **Default framing first:** the first shot is the player's default camera, captured **without posing it**: leave the game's camera controller running and only render. A hand-made "default" pose is always off somewhere (target, FOV, orbit basis). Add close-ups for small effects, at about 1–2 body heights from the subject.
- **Per-shot setup:** take over the camera and set the time of day at `f == 0` of every shot that needs it; with `ONLY` set for a retake, the other shots never run. If the game has a day/night clock, set the same hour at the start of each shot, or retakes come out with different lighting.
- **Moving platforms (ships, vehicles):** keep the camera pose in the platform's local space and convert with `TransformPoint` every frame, or the clip shakes against the platform. Smooth position only; aim the rotation at the target every frame. The template's `Fixed` and `Follow` hold the eye in world space: on a platform pick the eye once with `ClearEye`, store it with `InverseTransformPoint`, and `Look` from its `TransformPoint` each frame.
- **Following a character:** stand on the inside of the platform and look outward from above, or railings and walls cut the character off.
- **Hand control back:** stop the game's camera controller while posing (`enabled = false`) and re-enable it at the end.
- **Scenes that pose the camera themselves:** showcase and test scenes often set the camera in their own `Update` instead of a separate controller. There is nothing to disable: a pose set in `step` still wins, because the capture renders right after `step` in the same callback, and with `RESTORE_CAMERA = true` the scene's own pose comes back afterwards. Their default framing is whatever the scene sets (call its "reset view" method if it has one); leave it unposed for the first shot.

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
| Clip shows a wall, a roof or the inside of a building | A fixed offset from the subject; the subject walked behind a house, or the target sits behind a shed | `ClearEye` / `Follow` with buildings and props in `occluders`, and the subject's own root as `self` |
| The effect happens, but caused by something else (a passer-by flushes the birds before the dog arrives) | The trigger fired while the scene was not in its start state | In `step`, wait for the start state (all birds on the ground) before triggering, and check the cause in `done` |
| Recording lands in a folder named like `F:ecordings…` or the script fails with "Newline in constant" | A shell or a non-raw string turned `\r` / `\n` in a Windows path into control characters | `@"..."` verbatim strings in C#, raw strings (`r"..."`) in the script that edits them; no sed on Windows paths |
| Far shots show wrong LOD, missing terrain or ocean detail, or smearing | The camera is moved for the capture and put back: LOD, streaming and TAA history follow the restored pose, and one camera renders twice per frame | Disable the game's camera controller and set `RESTORE_CAMERA = false`, or keep shots near the game camera |

## 6. Screenshot sets

- **Mechanism:** a `still` shot in the template, one per camera pose. It runs its frames to let shaders, streaming and animation settle (20 frames is a reasonable start), saves the last, and `--batch` adds it to the page as an image.
- **One-off looks:** `capture_game_view -- --save_path Screenshots/x.png` (add `--source screen` to include overlay UI; Play mode only) or `screenshot -- --view game`. For those two, read `data.result.success`.
- **Lighting and sun:** a midday sun straight overhead flattens everything. Pick a time of day, and record it on the page.
- **Comparison pairs:** same pose, same time, same weather, one change.
- **Metadata:** write each shot's camera, game clock and weather into the manifest `fact`, so odd-looking frames can be checked against data before anyone acts on them.
