---
description: "Records review videos and screenshot sets of a running game, encodes them to captioned web-ready mp4, self-checks every clip through contact sheets, and builds a review page. Use when the user wants to see an effect, animation, AI behaviour or visual change in motion, asks for a video, clip, sample, screenshot set or before/after comparison, wants to look at a colleague's branch in action, or when a visible deliverable needs evidence before handoff. Unity is covered in depth; Godot and Unreal have reference notes."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md). Captions and page text go in that language too.

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-frames-to-mp4.py` exits 127. The `bin/*.py` files are bash wrappers: run them directly or with `bash`, not with `python`. They need Pillow and ffmpeg (system ffmpeg, or `python -m pip install pillow imageio-ffmpeg`); a missing one is reported with the install command.

Arguments: $ARGUMENTS — what to record (free text: the feature, the acceptance items, a branch or commit to look at). Optional `--out <dir>`: the `<topic>` folder (step 4) the recording goes under.

Copy this checklist into your reply and tick it off:

```
Recording progress:
- [ ] 1. Shot list: every visible item → one clip
- [ ] 2. Capture path picked
- [ ] 3. Scene controllable, effect verified to happen
- [ ] 4. Captured (frames + clips.json + done marker)
- [ ] 5. Encoded (qq-frames-to-mp4 --batch)
- [ ] 6. Contact sheets read, problems re-recorded
- [ ] 7. Review page built
- [ ] 8. Handed off: link + absolute local path + what was not recorded
```

## 1. Shot list

Write the list before touching the engine. One row per visible thing the user asked for or the acceptance criteria name, nothing skipped: users judge by watching, and an item without a clip counts as not delivered.

| Column | Rule |
|---|---|
| What to see | One sentence the viewer can check ("the keeper opens the gate, the hen walks out") |
| Medium | Anything that moves → video. Screenshots only for static looks (materials, layouts). Never GIF as the deliverable: palette reduction and downscaling read as "mosaic" |
| Camera | The player's default game camera first, then a close-up and a wide shot when the effect is small or spread out. Close-ups must avoid occluders (walls, railings) |
| Length | 10–20 s; rare or slow events longer, and note at which second they happen |
| Readback | The state that proves it worked (counts, HP, water depth, timings), read from the game at the start and end of the clip |

Before/after comparisons: lock camera, start state and time, random seed, and noisy post effects (TAA, motion blur, auto exposure); change one thing. Variants the user must choose between have to differ visibly from the default camera, and every clip says which side is which.

## 2. Pick the capture path

| Situation | Path |
|---|---|
| Quick look, no code change, any branch or commit (including a colleague's) | **Editor recorder**: copy [templates/unity_editor_recorder.cs](templates/unity_editor_recorder.cs), run it with `eval_file` in Play mode — [reference/unity.md](reference/unity.md) §1 |
| Acceptance evidence where the project judges effects in a player / development build | **Build reel**: a dev-only component started by a command-line switch — [reference/unity.md](reference/unity.md) §3 |
| Animation preview outside Play mode (editor-only preview scene) | [reference/unity.md](reference/unity.md) §2 |
| Godot / Unreal | [reference/godot.md](reference/godot.md) / [reference/unreal.md](reference/unreal.md) |

The Editor recorder needs the official Unity CLI (`eval_file`). Check the channel first: `${CLAUDE_PLUGIN_ROOT}/bin/qq-unity-cli.py channel --project "$PWD"` prints `unity-cli`, `tykit` or `none` ([`shared/unity-live-state.md`](../../shared/unity-live-state.md) explains them). On `tykit` or `none`, use the build reel. Call shapes and reply rules are in [`shared/unity-cli-reference.md`](../../shared/unity-cli-reference.md).

Recording a branch or commit you are not working on: check it out in a separate worktree and open that worktree's editor. Never switch the main checkout. Follow the project's rules for worktrees, editor slots and cleanup. The project's CLAUDE.md may also name a project-specific recording skill: read it first.

## 3. Make the scene controllable, and prove the effect happens

- Fixed seed, a test scene or preset that starts where the clip needs to be, direct state setters (place buildings, spawn units, set the clock) instead of waiting for the simulation.
- Trigger through the real game path (the debug panel's method, the actual damage call), not a test double.
- Dry-run each trigger once and read the state back. If nothing changes, fix the setup before recording. Example: water poured into an open area spreads over the whole connected floor and drowns nothing; a sealed room does. Never ship a clip where the effect does not occur, and tell the user when a debug button does nothing in that setup.
- Re-establish what the next clip needs (refill, respawn, repair). A previous clip may have destroyed it.

## 4. Capture

- Lock game time per frame (`Time.captureFramerate` in Unity, `--fixed-fps` in Godot): slow rendering then never drops or speeds up frames. Capture 120 and encode at 30 for 4x slow motion.
- Save `<out>/<clip>/f_00000.jpg …` at 1920×1080, plus `<out>/clips.json` (`[{"name", "title", "fps", "state"}]`) and `<out>/done.txt` (or `error.txt`). Optional per-frame captions in `<out>/<clip>/timeline.jsonl` (`{"f": 0, "caption": "..."}`).
- Screenshots: save `<out>/stills/<name>.jpg` and list them in `clips.json` as `{"name", "title", "still": true, "image": "stills/<name>.jpg", "state"}`. The Unity template does this for shots marked `still`.
- Layout: `<topic>/` holds your recorder script, `<topic>/rec` is `<out>` (wiped at each start, so nothing else goes in it).
- Retakes: when the whole shot list records in a minute or two, fix the script and re-record everything into `rec`. Otherwise record just the failed shots into `<topic>/rec-retake` with the template's `ONLY` list (it refuses to wipe an encoded `rec`), `--batch` that folder, and point the page item at the retake: `../../rec-retake/mp4/<shot>.mp4`, or `../../rec-retake/stills/<shot>.jpg` for a screenshot.
- Keep the recording root outside the engine's temp folders (Unity wipes `Temp/`), and don't record while tests, builds or other heavy jobs run on the same machine: frames stall and the editor can be killed for memory.
- Long captures run detached; wait for `done.txt` with a polling helper instead of fixed sleeps.

## 5. Encode

Run exactly this; don't hand-write encoders:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/qq-frames-to-mp4.py" --batch "<out>" --lang <page language, e.g. zh-CN> --page-title "<page title>"
```

It encodes up to 4 clips in parallel into `<out>/mp4/<clip>.mp4` (libx264, yuv420p, even dimensions, faststart; title bar from `clips.json`, per-frame captions from `timeline.jsonl`, slow-motion badge when a clip's `fps` exceeds 30) and writes `<out>/mp4/manifest.json`. It reads every output back and exits 1 on a wrong size, codec or pixel format. About 2 minutes for 3000 frames at 1080p.

One-off forms. Each input can be a frame directory or an existing video; without `--fps` a video keeps its own frame rate.

- `qq-frames-to-mp4.py <frames | video> -o x.mp4 --title "..." [--captions timeline.jsonl] [--capture-fps 120]`
- side by side: `qq-frames-to-mp4.py <before> --compare <after> --labels "before,after" --width 1920 -o cmp.mp4`
  - Labels are comma-separated. They sit at the bottom of each half and cover captions already burned into the bottom of the inputs: for such clips leave `--labels` off and say which side is which in `--title` or on the page.
  - The longer input is cut to the shorter; the script says so on stderr.
  - When the event happens at different seconds in the two inputs, align it with `--start-left <s>` / `--start-right <s>`.
- Clips that already carry burned-in captions: leave `--title` off, or it covers them.

Screenshot entries in `clips.json` are not encoded; they go into the manifest as images. A screenshot-only recording still goes through `--batch`: it writes a manifest with no videos.

**Working from existing clips** (a before/after of two earlier recordings, nothing to record):
1. Write step 1's row for each comparison: what changed and what to look at.
2. Skip steps 2–4.
3. Put everything in one folder `<out>/`: `cmp.mp4` from the side-by-side form above, then `qq-contact-sheet.py --batch <out>` (wide videos automatically get large single-column tiles).
4. `qq-review-page.py --scan <out> --lang <page language>` writes a draft page and `<out>/review.manifest.json` (it never overwrites an existing one). Fill that in, add `{"image": "sheets/<name>_sheet.jpg"}` items if a sheet helps the reader (`--scan` does not look into subfolders), and rebuild with `qq-review-page.py <out>/review.manifest.json`.

## 6. Self-check before anyone sees it

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/qq-contact-sheet.py" --batch "<out>/mp4"
```

Read every `<out>/mp4/sheets/*_sheet.jpg` with the image viewer tool. Screenshots: tile them with `qq-contact-sheet.py <out>/stills`, or read them one by one. Small effects (eggs, sparks, a number on a prop) can't be judged on 480 px tiles: also read one full-size frame of that clip. For each clip check that:

- the subject is in frame and large enough;
- nothing occludes it (walls, UI, other objects);
- the effect is visible;
- captions are readable;
- the order and timing match the shot list.

Fix and re-record failures; don't explain them away. Also confirm the frames are from this run, timestamps later than the start. A stale folder from an earlier run looks like success.

## 7. Review page

Edit `<out>/mp4/manifest.json`:

- `title` and `intro`: what was recorded, on which commit or build, when. `lang`: the page language (`zh-CN`, `ja`, …).
- `notes`: findings first, things that did not work or behaved unexpectedly.
- Per item `text`: what to look at. Per item `fact`: the readback, e.g. "hens 3 → 2".

Add screenshots as `{"image": ...}` items. Layout:

- Wide side-by-side videos span the whole row on their own.
- `"full": true` makes any item span the row.
- `"wide": true` on a section gives every item at least 560 px.
- Contact sheets are for your self-check; put one on the page only if it helps the reader.

Then:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/qq-review-page.py" "<out>/mp4/manifest.json"
```

It writes `<out>/mp4/index.html` with relative links and exits 1 listing any missing file. `qq-review-page.py --scan <dir>` builds a first draft from a folder of clips and screenshots.

## 8. Hand off

- If the project has a way to publish pages (a hook, a `pub`-style command, a docs host; check CLAUDE.md), publish and give the link. Also give the absolute local path. A page opened only on the local desktop does not reach a user who is away from the machine.
- In the reply: one line per clip, what it shows and its readback; what was not recorded and why; the findings from step 3.
- Stop Play mode and restore any settings or test presets you switched. Close editors and worktrees you opened only for recording once no more recording is planned in them (several recordings in a row share one editor; reopening can mean queueing again).

## Notes

- Recording is evidence, not a code change. A recorder script run through `eval_file` does not need a branch. A dev-build reel component is code and goes through the project's normal change flow.
- Visual-only checks in a build (lighting, shaders) need a real GPU. Batch-mode editors render nothing.
