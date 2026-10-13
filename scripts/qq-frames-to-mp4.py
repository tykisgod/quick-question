#!/usr/bin/env python3
"""把一个目录的逐帧图（按文件名排序）编成网页能直接放的 mp4，可叠标题、逐帧字幕，可左右并排对比。

用法：
  qq-frames-to-mp4.py <帧目录> -o out.mp4 [--fps 30] [--capture-fps 120] [--width 1280]
                      [--title "标题"] [--captions timeline.jsonl] [--compare <帧目录B> --labels "改前,改后"]
                      [--crf 23] [--preset medium]

- 帧在 Python 里缩放到目标尺寸（宽高取偶数），再以 rawvideo 喂给 ffmpeg：输出尺寸就是算出来的尺寸，
  不会像 imageio 的 write_frames 那样按 16 对齐把 1080 悄悄拉成 1088。
- 编码固定 libx264 + yuv420p + faststart（浏览器、手机都能放，边下边播）。crf 23 是 x264 的默认画质，
  长片嫌大调到 28，近景要细节调到 18。
- --captions：timeline.jsonl（每行 {"f": 帧号, "caption": "...", "info": "..."}）或 JSON 数组 [[帧号, "字"], ...]；
  一条字幕一直显示到下一条的帧号。
- --capture-fps：录的时候每游戏秒存了几帧。比 --fps 大就是慢放（录 120、放 30 = 0.25 倍速），右上角标出倍速。
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
    text = open(path, encoding="utf-8").read().strip()
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--fps", type=float, default=30.0, help="playback frame rate (default 30)")
    ap.add_argument("--capture-fps", type=float, default=None, help="frames saved per second of game time (default = --fps)")
    ap.add_argument("--width", type=int, default=None, help="output width; default = source width, at most 1920")
    ap.add_argument("--title", default="")
    ap.add_argument("--captions", default=None)
    ap.add_argument("--compare", default=None, help="second frame directory, shown on the right")
    ap.add_argument("--labels", default="", help="comma-separated labels for the left and right halves")
    ap.add_argument("--crf", type=int, default=23)
    ap.add_argument("--preset", default="medium")
    args = ap.parse_args()

    Image, _, _ = qq_media.pil()
    left = qq_media.list_frames(args.frames)
    right = qq_media.list_frames(args.compare) if args.compare else None
    count = len(left)
    if right is not None and len(right) != count:
        sys.stderr.write("qq-record: %d frames on the left, %d on the right; encoding the first %d\n"
                         % (len(left), len(right), min(len(left), len(right))))
        count = min(len(left), len(right))

    src_w, src_h = Image.open(left[0]).size
    halves = 2 if right is not None else 1
    width = args.width or min(src_w * halves, 1920)
    half_w = qq_media.even(width // halves)
    out_w = half_w * halves
    out_h = qq_media.even(round(half_w * src_h / src_w))
    labels = [s.strip() for s in args.labels.split(",")] if args.labels else []
    captions = load_captions(args.captions)
    capture_fps = args.capture_fps or args.fps
    speed_badge = "%g×" % round(args.fps / capture_fps, 3) if capture_fps > args.fps else ""

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    cmd = [qq_media.ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-y",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (out_w, out_h), "-r", "%g" % args.fps, "-i", "-",
           "-an", "-c:v", "libx264", "-preset", args.preset, "-crf", str(args.crf),
           "-pix_fmt", "yuv420p", "-movflags", "+faststart", args.output]
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
                if k < len(labels) and labels[k]:
                    label_h = max(label_h, qq_media.bar(tile, labels[k], top=False, size=label_size))
                frame.paste(tile, (k * half_w, 0))
            qq_media.bar(frame, args.title, top=True, size=title_size)
            cap = caption_at(captions, i)
            if cap:
                # 字幕摞在左右标签条上面，不盖住标签
                qq_media.bar(frame, cap, top=False, size=caption_size, offset=label_h)
            if speed_badge:
                badge = Image.new("RGB", (label_size * 4, int(label_size * 1.6)), (0, 0, 0))
                qq_media.bar(badge, speed_badge, top=True, size=label_size)
                frame.paste(badge, (out_w - badge.width, out_h // 8))
            proc.stdin.write(frame.tobytes())
        proc.stdin.close()
    except BrokenPipeError:
        pass
    if proc.wait() != 0:
        qq_media.die("ffmpeg failed (exit %d) writing %s" % (proc.returncode, args.output))

    info = qq_media.probe(args.output)
    problems = []
    if (info["width"], info["height"]) != (out_w, out_h):
        problems.append("size %sx%s, expected %dx%d" % (info["width"], info["height"], out_w, out_h))
    if info["codec"] != "h264":
        problems.append("codec %s, expected h264" % info["codec"])
    if info["pix_fmt"] != "yuv420p":
        problems.append("pixel format %s, expected yuv420p" % info["pix_fmt"])
    if problems:
        qq_media.die("%s: %s" % (args.output, "; ".join(problems)))
    print(json.dumps({"output": os.path.abspath(args.output), "frames": count, "fps": args.fps,
                      "seconds": round(count / args.fps, 2), "width": out_w, "height": out_h,
                      "codec": info["codec"], "pix_fmt": info["pix_fmt"], "speed": speed_badge or "1×"},
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
