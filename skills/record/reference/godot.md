# Recording in Godot 4

Godot has a built-in non-real-time recorder, Movie Maker mode. It works in the editor and in exported projects:

```bash
godot --path <project> --write-movie <out>/<clip>/frame.png --fixed-fps 30 --resolution 1920x1080 [--quit-after <frames>] [<scene.tscn>]
```

- Writing to a `.png` path produces a numbered PNG sequence plus a WAV: `frame00000000.png …`. That is the layout `qq-frames-to-mp4.py` reads. `.avi` (MJPEG, 4 GB limit) and `.ogv` (editor builds only) also exist; prefer PNG for the qq pipeline.
- `--fixed-fps` makes frame pacing perfect regardless of render speed. Audio is not audible while recording.
- **Stopping:** stop with `--quit-after N` or `get_tree().quit()` from a script. Ctrl+C or F8 can corrupt AVI/WAV output.
- **Headless:** `--headless` uses a dummy renderer and records nothing. Record on a machine with a GPU.
- **Per-clip setup:** do it in an autoload that reads `OS.get_cmdline_user_args()` (arguments after `--`). It positions the camera, triggers the event at a chosen frame, writes `clips.json` (`[{"name", "title", "fps", "state"}]`) next to the clip folders, and quits.
- **Screenshots:** `get_viewport().get_texture().get_image().save_png(path)` after `await RenderingServer.frame_post_draw`.

Then run `qq-frames-to-mp4.py --batch <out>` and continue with SKILL.md step 6.

Source: https://docs.godotengine.org/en/stable/tutorials/animation/creating_movies.html
