#!/usr/bin/env python3
"""qq:record 三个媒体脚本的公共部分：找 ffmpeg、找能写中文的字体、画字幕条、读视频信息。

依赖：Pillow（画字、拼图），ffmpeg（编码、读视频）。ffmpeg 的查找顺序：
环境变量 QQ_FFMPEG → PATH 上的 ffmpeg → imageio-ffmpeg 自带的那份（pip 装的 wheel 里带了可执行文件）。
"""
import contextlib
import os
import re
import shutil
import subprocess
import sys
import tempfile


def _utf8_stdio():
    # 路径、字幕里有中文；Windows 管道的默认编码不一定是 UTF-8（同 qq-unity-cli.py）
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
        except (AttributeError, ValueError):
            pass


_utf8_stdio()

# 能写中文、日文的系统字体，按平台列常见位置；都没有就退到 Pillow 自带字体（只有拉丁字母）。
FONT_CANDIDATES = [
    "C:/Windows/Fonts/msyh.ttc",
    "C:/Windows/Fonts/msyh.ttf",
    "C:/Windows/Fonts/simhei.ttf",
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
]

_warned_font = False


def die(msg):
    sys.stderr.write("qq-record: %s\n" % msg)
    sys.exit(1)


def ffmpeg_exe():
    exe = os.environ.get("QQ_FFMPEG") or shutil.which("ffmpeg")
    if exe:
        return exe
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:  # 没装或者 wheel 里没带可执行文件
        die("ffmpeg not found. Install it (brew install ffmpeg / winget install Gyan.FFmpeg / apt install ffmpeg), "
            "or `python -m pip install imageio-ffmpeg`, or set QQ_FFMPEG to the executable.")


def pil():
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        die("Pillow is required: python -m pip install pillow")
    return Image, ImageDraw, ImageFont


def font(size):
    global _warned_font
    _, _, ImageFont = pil()
    for path in [os.environ.get("QQ_FONT")] + FONT_CANDIDATES:
        if path and os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    if not _warned_font:
        sys.stderr.write("qq-record: no CJK font found, captions fall back to Pillow's default font; set QQ_FONT to a .ttf/.ttc\n")
        _warned_font = True
    try:
        return ImageFont.load_default(size)
    except TypeError:  # Pillow < 10.1 的 load_default 不收字号
        return ImageFont.load_default()


def wrap(draw, text, fnt, width):
    """按字符折行（中文没有空格可断），保留原有换行。"""
    lines = []
    for para in str(text).split("\n"):
        cur = ""
        for ch in para:
            if cur and draw.textlength(cur + ch, font=fnt) > width:
                lines.append(cur)
                cur = ch
            else:
                cur += ch
        lines.append(cur)
    return lines


_bar_cache = {}


def _bar_patch(text, width, size):
    """一条字幕条的 RGBA 贴片（半透明黑底、白字），按（字、宽、字号）缓存：同一句字每帧都一样，只画一次。"""
    key = (text, width, size)
    patch = _bar_cache.get(key)
    if patch is None:
        Image, ImageDraw, _ = pil()
        fnt = font(size)
        pad = max(4, size // 3)
        lines = wrap(ImageDraw.Draw(Image.new("RGBA", (1, 1))), text, fnt, width - 2 * pad)
        line_h = int(size * 1.35)
        patch = Image.new("RGBA", (width, pad * 2 + line_h * len(lines)), (0, 0, 0, 150))
        d = ImageDraw.Draw(patch)
        for i, line in enumerate(lines):
            d.text((pad, pad + i * line_h), line, font=fnt, fill=(255, 255, 255, 255))
        if len(_bar_cache) > 256:
            _bar_cache.clear()
        _bar_cache[key] = patch
    return patch


def bar(img, text, top, size, offset=0):
    """在图上压一条半透明黑底白字的字幕条：top=True 贴顶，否则贴底；offset 是离那条边让出的像素（摞在别的条上）。返回条高。
    只混合条所在的那一块（paste 带 alpha 遮罩），不对整张图做合成：1080p 每帧省下大半时间。"""
    if not text:
        return 0
    patch = _bar_patch(str(text), img.width, size)
    y0 = offset if top else img.height - patch.height - offset
    img.paste(patch, (0, y0), patch)
    return patch.height


def probe(path):
    """用 ffmpeg 读一个视频：时长（秒）、编码、像素格式、宽高、帧率。读不出的项为 None。"""
    err = subprocess.run([ffmpeg_exe(), "-hide_banner", "-i", path], capture_output=True, text=True,
                         errors="replace").stderr
    info = {"duration": None, "codec": None, "pix_fmt": None, "width": None, "height": None, "fps": None}
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", err)
    if m:
        info["duration"] = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    m = re.search(r"Video: (\w+)", err)
    if m:
        info["codec"] = m.group(1)
    m = re.search(r"Video: [^,]+, ([a-z0-9]+)", err)
    if m:
        info["pix_fmt"] = m.group(1)
    m = re.search(r"Video: .*?, (\d{2,5})x(\d{2,5})", err)
    if m:
        info["width"], info["height"] = int(m.group(1)), int(m.group(2))
    m = re.search(r"([\d.]+) fps", err)
    if m:
        info["fps"] = float(m.group(1))
    return info


IMAGE_EXT = (".jpg", ".jpeg", ".png", ".bmp", ".webp")


def list_frames(directory):
    if not os.path.isdir(directory):
        die("not a directory: %s" % directory)
    frames = sorted(os.path.join(directory, n) for n in os.listdir(directory) if n.lower().endswith(IMAGE_EXT))
    if not frames:
        die("no frames (%s) in %s" % ("/".join(IMAGE_EXT), directory))
    return frames


@contextlib.contextmanager
def frames_of(path):
    """一个帧来源：帧目录直接列图；视频文件先用 ffmpeg 按它自己的帧率解到临时目录（用完删掉）。"""
    if os.path.isdir(path):
        yield list_frames(path)
        return
    if not os.path.isfile(path):
        die("not a frame directory or a video file: %s" % path)
    tmp = tempfile.mkdtemp(prefix="qq-record-")
    try:
        r = subprocess.run([ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-i", path, "-q:v", "2",
                            os.path.join(tmp, "f_%06d.jpg")], capture_output=True, text=True, errors="replace")
        if r.returncode != 0:
            die("ffmpeg could not decode %s: %s" % (path, r.stderr.strip()[-300:]))
        yield list_frames(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def even(n):
    return max(2, int(n) - int(n) % 2)
