#!/usr/bin/env python3
"""从一段视频或一个帧目录均匀抽几帧，拼成一张带时间标签的图，用来在发出去之前自己看一遍。

用法：
  qq-contact-sheet.py <视频.mp4 | 帧目录> [-o sheet.jpg] [--count 9] [--cols 3] [--tile-width 480] [--fps 30]

- 视频按时长等分取每段的中点；帧目录按帧数等分（标签按 --fps 换算成秒，默认 30）。
- 每格右下角写时间（视频）或帧号加秒数（帧目录）。不给 -o 就写在输入旁边：<名>_sheet.jpg。
- 成功时 stdout 打一行 JSON（输出路径、格数、宽高）。拼好后用看图的工具把这张图读进来看。
"""
import argparse
import io
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qq_media  # noqa: E402


def video_frames(path, count):
    info = qq_media.probe(path)
    if not info["duration"]:
        qq_media.die("cannot read the duration of %s" % path)
    Image, _, _ = qq_media.pil()
    out = []
    for i in range(count):
        t = (i + 0.5) * info["duration"] / count
        png = subprocess.run([qq_media.ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-ss", "%.3f" % t,
                              "-i", path, "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-"],
                             capture_output=True).stdout
        if not png:
            qq_media.die("ffmpeg returned no frame at %.2fs of %s" % (t, path))
        out.append((Image.open(io.BytesIO(png)).convert("RGB"), "%.1fs" % t))
    return out


def dir_frames(path, count, fps):
    Image, _, _ = qq_media.pil()
    frames = qq_media.list_frames(path)
    count = min(count, len(frames))
    picks = [round(i * (len(frames) - 1) / max(1, count - 1)) for i in range(count)]
    return [(Image.open(frames[k]).convert("RGB"), "#%d  %.1fs" % (k, k / fps)) for k in picks]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--count", type=int, default=9)
    ap.add_argument("--cols", type=int, default=3)
    ap.add_argument("--tile-width", type=int, default=480)
    ap.add_argument("--fps", type=float, default=30.0, help="frame rate used to label frame-directory tiles")
    args = ap.parse_args()

    Image, ImageDraw, _ = qq_media.pil()
    source = args.source.rstrip("/\\")
    tiles = dir_frames(source, args.count, args.fps) if os.path.isdir(source) else video_frames(source, args.count)
    first = tiles[0][0]
    tw = args.tile_width
    th = qq_media.even(round(tw * first.height / first.width))
    cols = min(args.cols, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * tw, rows * th), (24, 24, 24))
    for i, (img, label) in enumerate(tiles):
        tile = img.resize((tw, th), Image.LANCZOS)
        # 时间标签只占字那么宽，贴右下角：片子的标题、字幕、并排标签多在顶上和左下，不挡它们
        size = max(10, th // 14)
        fnt = qq_media.font(size)
        d = ImageDraw.Draw(tile)
        w = int(d.textlength(label, font=fnt)) + size
        d.rectangle([tw - w, th - int(size * 1.6), tw, th], fill=(0, 0, 0))
        d.text((tw - w + size // 2, th - int(size * 1.45)), label, font=fnt, fill=(255, 255, 0))
        sheet.paste(tile, ((i % cols) * tw, (i // cols) * th))
    output = args.output or os.path.splitext(source)[0] + "_sheet.jpg"
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    sheet.save(output, quality=85)
    print(json.dumps({"output": os.path.abspath(output), "tiles": len(tiles), "width": sheet.width,
                      "height": sheet.height}, ensure_ascii=False))


if __name__ == "__main__":
    main()
