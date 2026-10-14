#!/usr/bin/env python3
"""把逐帧图（一个目录，按文件名排序）或现成的视频编成网页能直接放的 mp4，可叠标题、逐帧字幕，可左右并排对比。

用法：
  qq-frames-to-mp4.py <帧目录|视频> -o out.mp4 [--fps 30] [--capture-fps 120] [--width 1280]
                      [--title "标题"] [--captions timeline.jsonl] [--compare <帧目录|视频> --labels "改前,改后"]
                      [--crf 23] [--preset medium]
  qq-frames-to-mp4.py --batch <录像目录>     # 按目录里的 clips.json 一段段编到 <录像目录>/mp4/，并写出 mp4/manifest.json

- 帧在 Python 里缩放到目标尺寸（宽高取偶数），再以 rawvideo 喂给 ffmpeg：输出尺寸就是算出来的尺寸，
  不会像 imageio 的 write_frames 那样按 16 对齐把 1080 悄悄拉成 1088。
- 视频输入按它自己的帧率解成帧再编；不给 --fps 时就用左边那段的帧率（帧目录按 30）。已经压过字幕的旧片子别再加 --title，
  会盖住原字幕。两段长短不一按短的截齐（stderr 会说）；事件时刻对不上，用 --start-left / --start-right（秒）把起点对齐。
- 编码固定 libx264 + yuv420p + faststart（浏览器、手机都能放，边下边播）。crf 23 是 x264 的默认画质，
  长片嫌大调到 28，近景要细节调到 18。
- --captions：timeline.jsonl（每行 {"f": 帧号, "caption": "...", "info": "..."}）或 JSON 数组 [[帧号, "字"], ...]；
  一条字幕一直显示到下一条的帧号。
- --capture-fps：录的时候每游戏秒存了几帧。比 --fps 大就是慢放（录 120、放 30 = 0.25 倍速），标题条下面标出倍速。
- --batch：clips.json 是录像器写的 [{"name": 子目录, "title": 字幕标题, "fps": 录制帧率, "state": 读回的状态}, ...]；
  每段子目录里有 timeline.jsonl 就当逐帧字幕用。截图条目（{"still": true, "image": "stills/x.jpg"}）不编码，
  直接作为图片放进清单。写出的 manifest.json 可以直接交给 qq-review-page.py（先补上每段看什么）。
- 编完用 ffmpeg 读回输出核对尺寸、编码、像素格式，对不上退 1。成功时 stdout 打一行 JSON。
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qq_media  # noqa: E402


def load_captions(path):
    """返回按帧号排好的 [(帧号, 文字)]。"""
    if not path:
        return []
    with open(path, encoding="utf-8") as f:
        text = f.read().strip()
    out = []
    if text.startswith("["):
        for frame, caption in json.loads(text):
            out.append((int(frame), str(caption)))
    else:
        for line in text.splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            caption = row.get("caption", "")
            if row.get("info"):
                caption = (caption + "\n" + row["info"]) if caption else row["info"]
            out.append((int(row["f"]), caption))
    return sorted(out, key=lambda r: r[0])


def caption_at(captions, frame):
    current = ""
    for start, text in captions:
        if start > frame:
            break
        current = text
    return current


def encode(left_src, output, fps=None, capture_fps=None, width=None, title="", captions_path=None,
           right_src=None, labels="", crf=23, preset="medium", start_left=0.0, start_right=0.0):
    """编一段，返回摘要 dict；任何不对就 die。left_src / right_src 是帧目录或视频文件。
    fps 不给时：左边是视频就用它的帧率，是帧目录就按 30。start_left / start_right：两边各从第几秒开始（对齐事件）。"""
    if fps is None:
        fps = (qq_media.probe(left_src)["fps"] if os.path.isfile(left_src) else None) or 30.0
    with qq_media.frames_of(left_src) as left:
        left = left[int(round(start_left * fps)):]
        if not left:
            qq_media.die("--start-left %.2fs is past the end of %s" % (start_left, left_src))
        if right_src:
            with qq_media.frames_of(right_src) as right:
                right = right[int(round(start_right * fps)):]
                if not right:
                    qq_media.die("--start-right %.2fs is past the end of %s" % (start_right, right_src))
                return _encode(left, right, output, fps, capture_fps, width, title, captions_path, labels, crf, preset)
        return _encode(left, None, output, fps, capture_fps, width, title, captions_path, labels, crf, preset)


def _encode(left, right, output, fps, capture_fps, width, title, captions_path, labels, crf, preset):
    Image, _, _ = qq_media.pil()
    count = len(left)
    if right is not None and len(right) != count:
        sys.stderr.write("qq-record: %d frames on the left, %d on the right; encoding the first %d\n"
                         % (len(left), len(right), min(len(left), len(right))))
        count = min(len(left), len(right))

    src_w, src_h = Image.open(left[0]).size
    if right is not None:
        rw, rh = Image.open(right[0]).size
        if abs(rw / rh - src_w / src_h) > 0.01:
            sys.stderr.write("qq-record: right side is %dx%d, left is %dx%d; the right side is stretched to the left's shape\n"
                             % (rw, rh, src_w, src_h))
    halves = 2 if right is not None else 1
    width = width or min(src_w * halves, 1920)
    half_w = qq_media.even(width // halves)
    out_w = half_w * halves
    out_h = qq_media.even(round(half_w * src_h / src_w))
    label_list = [s.strip() for s in labels.split(",")] if labels else []
    captions = load_captions(captions_path)
    capture_fps = capture_fps or fps
    speed_badge = "%g×" % round(fps / capture_fps, 3) if capture_fps > fps else ""

    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    cmd = [qq_media.ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-y",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (out_w, out_h), "-r", "%g" % fps, "-i", "-",
           "-an", "-c:v", "libx264", "-preset", preset, "-crf", str(crf),
           "-pix_fmt", "yuv420p", "-movflags", "+faststart", output]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    title_size = max(14, out_h // 22)
    caption_size = max(12, out_h // 26)
    label_size = max(12, out_h // 20)
    try:
        for i in range(count):
            frame = Image.new("RGB", (out_w, out_h))
            sources = [left[i]] + ([right[i]] if right is not None else [])
            label_h = 0
            for k, path in enumerate(sources):
                tile = Image.open(path).convert("RGB").resize((half_w, out_h), Image.LANCZOS)
                if k < len(label_list) and label_list[k]:
                    label_h = max(label_h, qq_media.bar(tile, label_list[k], top=False, size=label_size))
                frame.paste(tile, (k * half_w, 0))
            title_h = qq_media.bar(frame, title, top=True, size=title_size)
            cap = caption_at(captions, i)
            if cap:
                # 字幕摞在左右标签条上面，不盖住标签
                qq_media.bar(frame, cap, top=False, size=caption_size, offset=label_h)
            if speed_badge:
                # 倍速角标放在标题条下面的右侧：标题折成几行也压不住
                badge = Image.new("RGB", (label_size * 4, int(label_size * 1.6)), (0, 0, 0))
                qq_media.bar(badge, speed_badge, top=True, size=label_size)
                frame.paste(badge, (out_w - badge.width, title_h + label_size // 2))
            proc.stdin.write(frame.tobytes())
        proc.stdin.close()
    except BrokenPipeError:
        pass
    if proc.wait() != 0:
        qq_media.die("ffmpeg failed (exit %d) writing %s" % (proc.returncode, output))

    info = qq_media.probe(output)
    problems = []
    if (info["width"], info["height"]) != (out_w, out_h):
        problems.append("size %sx%s, expected %dx%d" % (info["width"], info["height"], out_w, out_h))
    if info["codec"] != "h264":
        problems.append("codec %s, expected h264" % info["codec"])
    if info["pix_fmt"] != "yuv420p":
        problems.append("pixel format %s, expected yuv420p" % info["pix_fmt"])
    if problems:
        qq_media.die("%s: %s" % (output, "; ".join(problems)))
    return {"output": os.path.abspath(output), "frames": count, "fps": fps, "seconds": round(count / fps, 2),
            "width": out_w, "height": out_h, "codec": info["codec"], "pix_fmt": info["pix_fmt"],
            "speed": speed_badge or "1×"}


def batch(directory, args):
    """按录像目录里的 clips.json 一段段编到 <目录>/mp4/，再写一份 qq-review-page 能直接用的清单。"""
    meta_path = os.path.join(directory, "clips.json")
    if not os.path.exists(meta_path):
        qq_media.die("no clips.json in %s (the recorder writes it when it finishes; check done.txt / error.txt)" % directory)
    with open(meta_path, encoding="utf-8") as f:
        clips = json.load(f)
    if not clips:
        qq_media.die("%s lists no clips" % meta_path)
    out_dir = os.path.join(directory, "mp4")
    results, items = [], []
    for clip in clips:
        name = clip["name"]
        if clip.get("still"):
            image = os.path.join(directory, clip.get("image") or os.path.join("stills", name + ".jpg"))
            if not os.path.exists(image):
                qq_media.die("still %s: %s does not exist" % (name, image))
            items.append({"image": os.path.relpath(image, out_dir).replace(os.sep, "/"), "title": clip.get("title", name),
                          "text": "", "fact": clip.get("state", "")})
            continue
        captions = os.path.join(directory, name, "timeline.jsonl")
        r = encode(os.path.join(directory, name), os.path.join(out_dir, name + ".mp4"), fps=args.fps,
                   capture_fps=clip.get("fps") or args.capture_fps, width=args.width, title=clip.get("title", ""),
                   captions_path=captions if os.path.exists(captions) else None, crf=args.crf, preset=args.preset)
        results.append(r)
        items.append({"video": name + ".mp4", "title": clip.get("title", name), "text": "",
                      "fact": clip.get("state", ""), "seconds": r["seconds"]})
        sys.stderr.write("qq-record: %s  %.1fs  %dx%d\n" % (name, r["seconds"], r["width"], r["height"]))
    os.makedirs(out_dir, exist_ok=True)
    manifest = {"title": os.path.basename(os.path.abspath(directory)), "intro": "", "lang": "en", "notes": [],
                "sections": [{"title": "", "items": items}]}
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    return {"clips": results, "items": len(items), "manifest": os.path.abspath(os.path.join(out_dir, "manifest.json"))}


def main():
    ap = argparse.ArgumentParser(
        description="Encode a frame directory or a video into a captioned, web-ready H.264 mp4 "
                    "(optionally side by side), or encode every clip of a recording with --batch.",
        epilog=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames", nargs="?", help="frame directory or video file")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--batch", default=None, help="recording directory with clips.json: encode every clip into <dir>/mp4/")
    ap.add_argument("--fps", type=float, default=None,
                    help="playback frame rate; default: the input video's own rate, or 30 for frame directories")
    ap.add_argument("--capture-fps", type=float, default=None, help="frames saved per second of game time (default = --fps)")
    ap.add_argument("--width", type=int, default=None, help="output width; default = source width, at most 1920")
    ap.add_argument("--title", default="", help="title bar; leave it off for videos that already carry their own captions")
    ap.add_argument("--captions", default=None)
    ap.add_argument("--compare", default=None, help="second frame directory or video, shown on the right")
    ap.add_argument("--labels", default="", help="comma-separated labels for the left and right halves (no ASCII comma inside a label)")
    ap.add_argument("--start-left", type=float, default=0.0, help="skip this many seconds of the left input (align events)")
    ap.add_argument("--start-right", type=float, default=0.0, help="skip this many seconds of the right input (align events)")
    ap.add_argument("--crf", type=int, default=23)
    ap.add_argument("--preset", default="medium")
    args = ap.parse_args()

    if args.batch:
        args.fps = args.fps or 30.0
        print(json.dumps(batch(args.batch, args), ensure_ascii=False))
        return
    if not args.frames or not args.output:
        qq_media.die("give <frames dir | video> -o <out.mp4>, or --batch <recording dir>")
    print(json.dumps(encode(args.frames, args.output, fps=args.fps, capture_fps=args.capture_fps, width=args.width,
                            title=args.title, captions_path=args.captions, right_src=args.compare,
                            labels=args.labels, crf=args.crf, preset=args.preset,
                            start_left=args.start_left, start_right=args.start_right), ensure_ascii=False))


if __name__ == "__main__":
    main()
