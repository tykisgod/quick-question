#!/usr/bin/env python3
"""从一段视频或一个帧目录均匀抽几帧，拼成一张带时间标签的图，用来在发出去之前自己看一遍。

用法：
  qq-contact-sheet.py <视频.mp4 | 帧目录> [-o sheet.jpg] [--count 9] [--cols 3] [--tile-width 480] [--fps 30]
  qq-contact-sheet.py --batch <目录>     # 目录里每个 mp4 各出一张，写到 <目录>/sheets/<名>_sheet.jpg

- 视频按时长等分取每段的中点；帧目录按帧数等分（标签按 --fps 换算成秒，默认 30）。
- 宽画面（宽高比 2.2 以上，左右并排的对比片）默认 4 格、一列、每格 1440 宽，字幕看得清；给了参数就照参数。
- 一组截图（不超过 9 张，或文件名不是 f_00000 这种同一前缀加序号）默认全放上、两列、每格 960 宽（宽图一列 1440），
  每格写文件名。
- 每格右下角写时间（视频）、帧号加秒数（逐帧目录）或文件名（截图组）。不给 -o 就写在输入旁边：<名>_sheet.jpg。
- 成功时 stdout 打一行 JSON（输出路径、格数、宽高）。拼好后用看图的工具把这张图读进来看。
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qq_media  # noqa: E402

VIDEO_EXT = (".mp4", ".webm", ".m4v", ".mov")


def video_frames(path, count):
    info = qq_media.probe(path)
    if not info["duration"]:
        qq_media.die("cannot read the duration of %s" % path)
    Image, _, _ = qq_media.pil()
    out = []
    step = 1.0 / (info["fps"] or 30.0)
    # ffmpeg 报的时长取到 0.01 秒，最后一帧的时间可能比它早一帧多：留一帧半，取不到再一帧帧往前退
    last_frame = max(0.0, info["duration"] - 1.5 * step)
    for i in range(count):
        t = min((i + 0.5) * info["duration"] / count, last_frame)
        png = b""
        for _ in range(4):
            png = subprocess.run([qq_media.ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-ss", "%.3f" % t,
                                  "-i", path, "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-"],
                                 capture_output=True).stdout
            if png or t <= 0:
                break
            t = max(0.0, t - step)
        if not png:
            qq_media.die("ffmpeg returned no frame at %.2fs of %s" % (t, path))
        out.append((Image.open(io.BytesIO(png)).convert("RGB"), "%.1fs" % t))
    return out


def is_sequence(frames):
    """逐帧序列（f_00000.jpg、movie00000001.png：同一前缀加序号）还是一组截图（各有各的名字）。"""
    stems = [os.path.splitext(os.path.basename(p))[0] for p in frames]
    return all(re.search(r"\d$", s) for s in stems) and len({re.sub(r"\d+$", "", s) for s in stems}) == 1


def dir_frames(path, count, fps, stills):
    frames = qq_media.list_frames(path)
    count = min(count, len(frames))
    picks = [round(i * (len(frames) - 1) / max(1, count - 1)) for i in range(count)]
    return [(qq_media.open_image(frames[k]).convert("RGB"),
             os.path.basename(frames[k]) if stills else "#%d  %.1fs" % (k, k / fps)) for k in picks]


def make_sheet(source, output, count, cols, tile_width, fps, stills=False):
    Image, ImageDraw, _ = qq_media.pil()
    source = source.rstrip("/\\")
    tiles = dir_frames(source, count, fps, stills) if os.path.isdir(source) else video_frames(source, count)
    first = tiles[0][0]
    tw = tile_width
    th = qq_media.even(round(tw * first.height / first.width))
    cols = min(cols, len(tiles))
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
    output = output or os.path.splitext(source)[0] + "_sheet.jpg"
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    sheet.save(output, quality=85)
    return {"output": os.path.abspath(output), "tiles": len(tiles), "width": sheet.width, "height": sheet.height}


def main():
    ap = argparse.ArgumentParser(
        description="Tile evenly spaced frames of a video or frame directory into one labelled image for a quick self-check.",
        epilog=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", nargs="?", help="video file or frame directory")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--batch", default=None, help="make one sheet per video in this directory, into <dir>/sheets/")
    ap.add_argument("--count", type=int, default=None, help="tiles (default 9; 4 for wide side-by-side videos)")
    ap.add_argument("--cols", type=int, default=None, help="columns (default 3; 1 for wide videos)")
    ap.add_argument("--tile-width", type=int, default=None, help="tile width in px (default 480; 1440 for wide videos)")
    ap.add_argument("--fps", type=float, default=30.0, help="frame rate used to label frame-directory tiles")
    args = ap.parse_args()
    for name in ("count", "cols", "tile_width"):
        value = getattr(args, name)
        if value is not None and value < (16 if name == "tile_width" else 1):
            qq_media.die("--count and --cols must be at least 1, --tile-width at least 16")

    def sheet(source, output):
        # 宽画面（左右并排的对比片）默认改成一列大格：小格子里每半边只剩两百来像素，字幕看不清
        stills = False
        if os.path.isdir(source):
            frames = qq_media.list_frames(source)
            w, h = qq_media.open_image(frames[0]).size
            # 一组截图而不是逐帧序列：每张都要看到，两列大格（三百来像素的小格看不出东西）
            stills = len(frames) <= 9 or not is_sequence(frames)
        else:
            info = qq_media.probe(source)
            w, h = info["width"] or 16, info["height"] or 9
        wide = w / h >= 2.2
        if stills:
            return make_sheet(source, output, args.count or len(frames), args.cols or (1 if wide else 2),
                              args.tile_width or (1440 if wide else 960), args.fps, stills=True)
        return make_sheet(source, output, args.count or (4 if wide else 9), args.cols or (1 if wide else 3),
                          args.tile_width or (1440 if wide else 480), args.fps)

    if args.batch:
        videos = sorted(n for n in os.listdir(args.batch) if n.lower().endswith(VIDEO_EXT))
        if not videos:
            qq_media.die("no videos in %s" % args.batch)
        out = [sheet(os.path.join(args.batch, n), os.path.join(args.batch, "sheets", os.path.splitext(n)[0] + "_sheet.jpg"))
               for n in videos]
        print(json.dumps(out, ensure_ascii=False))
        return
    if not args.source:
        qq_media.die("give <video | frames dir>, or --batch <dir>")
    print(json.dumps(sheet(args.source.rstrip("/\\"), args.output), ensure_ascii=False))


if __name__ == "__main__":
    main()
