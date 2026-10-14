#!/usr/bin/env python3
"""按一份清单（JSON）出一页验收网页：每段视频或截图配标题、一句看什么、一行实测数。

用法：
  qq-review-page.py <清单.json> [-o 页面.html]
  qq-review-page.py --scan <目录> [-o 页面.html]     # 把目录里的 mp4 / 图片按文件名排成一页，顺带写出清单供改

清单格式（路径都相对清单所在目录；页面里的链接会换算成相对页面的路径，页面和媒体可以分开放）：
  {"title": "...", "intro": "...", "lang": "zh-CN", "notes": ["页头要先说的事", ...],
   "sections": [{"title": "...", "intro": "...", "wide": false,
                 "items": [{"video": "clips/a.mp4", "title": "...", "text": "看什么", "fact": "实测：3 → 2 只",
                            "slow": "clips/a_slow.mp4", "slow_factor": 4},
                           {"image": "shots/b.jpg", "title": "..."}]}]}
  "wide": true 让这一节每格至少 560 px 宽；条目 "full": true 占满一整行。不写 full 时，宽高比 2.2 以上的视频和图片
  （左右并排的对比片）自动占满一行。图片可以点开看原图。--lang 设页面语言（--scan 草稿默认 en）。
  "slow"：同一段的慢放版，页面上放的仍是 "video"（原速），慢放只在图注下给一个链接（「4 倍慢放」，按页面语言）。

- 引用的文件有一个不存在就退 1 并列出来，不出半截页面。
- 视频没写 "seconds" 时用 ffmpeg 读时长（没有 ffmpeg 就提示一次、不写时长）。--scan 的草稿清单写在扫描目录里
  （review.manifest.json），改完拿它重出；它已经在了就不覆盖（免得冲掉改过的），要重扫先删掉它。
- --scan 只扫这一层目录，不进子目录（拼图在 sheets/ 里）：要放上页面就在清单里手加 {"image": "sheets/<名>_sheet.jpg"}。
- 页面只用相对路径和内联样式，不连外网；视频是 <video controls muted loop playsinline>。
"""
import argparse
import html
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qq_media  # noqa: E402

VIDEO_EXT = (".mp4", ".webm", ".m4v", ".mov")

STYLE = """
:root { --bg:#fbfbfa; --fg:#2c2b29; --muted:#6b6a66; --line:#d6d5d1; --card:#fff; --note:#fbf3df; --note-line:#d9a441; --fact:#3d7a57; }
@media (prefers-color-scheme: dark) { :root { --bg:#1d1c1a; --fg:#e6e4df; --muted:#a3a19b; --line:#3a3936; --card:#262523; --note:#3a3220; --note-line:#a8812f; --fact:#7fc29b; } }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.7 "Microsoft YaHei","PingFang SC",system-ui,sans-serif; }
main { max-width:1240px; margin:0 auto; padding:24px 16px 60px; }
h1 { font-size:24px; margin:0 0 6px; } h2 { font-size:19px; margin:34px 0 6px; padding-top:10px; border-top:1px solid var(--line); }
p { margin:4px 0; } .muted { color:var(--muted); font-size:13.5px; }
.note { background:var(--note); border:1px solid var(--note-line); border-radius:6px; padding:10px 14px; margin:14px 0; }
.note ul { margin:4px 0; padding-left:20px; }
.grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(380px,1fr)); gap:18px; margin-top:12px; }
.grid.wide { grid-template-columns:repeat(auto-fill,minmax(560px,1fr)); }
figure.full { grid-column:1 / -1; }
figure { margin:0; background:var(--card); border:1px solid var(--line); border-radius:6px; overflow:hidden; }
video, figure img { width:100%; display:block; background:#000; }
figcaption { padding:8px 12px 10px; font-size:14px; } figcaption b { display:block; font-size:15px; }
.len { color:var(--muted); font-weight:normal; font-size:12.5px; margin-left:6px; } .fact { color:var(--fact); font-size:13.5px; }
@media (max-width:640px) { .grid, .grid.wide { grid-template-columns:1fr; } }
"""


def esc(s):
    return html.escape(str(s or ""))


def slow_label(lang, factor):
    """慢放链接的字：按页面语言，写明慢几倍。"""
    n = ("%g" % factor) if factor else ""
    lang = (lang or "en").lower()
    if lang.startswith("zh"):
        return "%s 倍慢放" % n if n else "慢放"
    if lang.startswith("ja"):
        return "%s倍スロー" % n if n else "スロー"
    return "%s× slow motion" % n if n else "slow motion"


def scan(directory, lang):
    names = sorted(n for n in os.listdir(directory) if n.lower().endswith(VIDEO_EXT + qq_media.IMAGE_EXT))
    if not names:
        qq_media.die("no videos or images in %s" % directory)
    items = []
    for n in names:
        stem, ext = os.path.splitext(n)
        if stem.endswith("_slow") and stem[:-5] + ext in names:
            continue   # 某段的慢放版：挂在那一段下面当链接，不单列
        key = "video" if n.lower().endswith(VIDEO_EXT) else "image"
        item = {key: n, "title": stem, "text": "", "fact": ""}
        if stem + "_slow" + ext in names:
            item["slow"] = stem + "_slow" + ext
        items.append(item)
    return {"title": os.path.basename(os.path.abspath(directory)), "intro": "", "lang": lang, "notes": [],
            "sections": [{"title": "", "items": items}]}


def main():
    ap = argparse.ArgumentParser(
        description="Build a self-contained review page (videos and screenshots with titles, notes and measured facts) "
                    "from a JSON manifest, or a first draft from a folder with --scan.",
        epilog=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest", nargs="?")
    ap.add_argument("--scan", default=None, help="build the page from every video/image in this directory")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--lang", default=None, help="page language (zh-CN, ja, ...); overrides the manifest, default en")
    args = ap.parse_args()
    if bool(args.manifest) == bool(args.scan):
        qq_media.die("give either a manifest or --scan <dir>")

    if args.scan:
        base = os.path.abspath(args.scan)
        data = scan(base, args.lang or "en")
        output = os.path.abspath(args.output or os.path.join(base, "index.html"))
        # 草稿清单写在扫描目录里：里面的路径相对它，改完直接 `qq-review-page.py <它> -o ...` 重出
        draft = os.path.join(base, "review.manifest.json")
        if os.path.exists(draft):
            qq_media.die("%s already exists (it may hold your edits): rebuild with `qq-review-page.py %s`, "
                         "or delete it to scan again" % (draft, draft))
        with open(draft, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
    else:
        base = os.path.dirname(os.path.abspath(args.manifest))
        with open(args.manifest, encoding="utf-8") as f:
            data = json.load(f)
        if args.lang:
            data["lang"] = args.lang
        output = os.path.abspath(args.output or os.path.join(base, "index.html"))
    out_dir = os.path.dirname(output)

    missing = []
    for section in data.get("sections", []):
        for item in section.get("items", []):
            path = item.get("video") or item.get("image")
            if not path or not os.path.exists(os.path.join(base, path)):
                missing.append(path or "(item without video/image: %s)" % item.get("title", "?"))
            if item.get("slow") and not os.path.exists(os.path.join(base, item["slow"])):
                missing.append(item["slow"])
    if missing:
        qq_media.die("missing files (relative to %s): %s" % (base, ", ".join(missing)))

    parts = ['<!doctype html>\n<html lang="%s">\n<head>\n<meta charset="utf-8">' % esc(data.get("lang", "en")),
             '<meta name="viewport" content="width=device-width, initial-scale=1">',
             "<title>%s</title>\n<style>%s</style>\n</head>\n<body>\n<main>" % (esc(data.get("title")), STYLE),
             "<h1>%s</h1>" % esc(data.get("title"))]
    for para in str(data.get("intro", "")).split("\n"):
        if para.strip():
            parts.append("<p>%s</p>" % esc(para))
    if data.get("notes"):
        parts.append('<div class="note"><ul>%s</ul></div>' % "".join("<li>%s</li>" % esc(n) for n in data["notes"]))
    try:
        qq_media.ffmpeg_exe()
        have_ffmpeg = True
    except SystemExit:  # 没有 ffmpeg 也照样出页，只是不写时长、不判视频宽窄；上面那句提示只打一次
        sys.stderr.write("qq-record: building the page without video lengths\n")
        have_ffmpeg = False
    def rel_to_page(path):
        try:
            return os.path.relpath(os.path.join(base, path), out_dir).replace(os.sep, "/")
        except ValueError:  # Windows：页面和媒体不在同一个盘，没有相对路径
            qq_media.die("%s and the page %s are on different drives; write the page next to the media" % (path, output))

    count = 0
    for section in data.get("sections", []):
        if section.get("title"):
            parts.append("<h2>%s</h2>" % esc(section["title"]))
        if section.get("intro"):
            parts.append('<p class="muted">%s</p>' % esc(section["intro"]))
        parts.append('<div class="grid%s">' % (" wide" if section.get("wide") else ""))
        for item in section.get("items", []):
            path = item.get("video") or item.get("image")
            rel = rel_to_page(path)
            seconds = item.get("seconds")
            size = None
            if item.get("video"):
                if have_ffmpeg:
                    info = qq_media.probe(os.path.join(base, path))
                    seconds = seconds if seconds is not None else info["duration"]
                    size = (info["width"], info["height"])
                media = '<video controls muted loop playsinline preload="metadata" src="%s"></video>' % esc(rel)
            else:
                try:
                    Image, _, _ = qq_media.pil()
                    size = Image.open(os.path.join(base, path)).size
                except (SystemExit, OSError):
                    pass
                # 图片点开看原图
                media = '<a href="%s" target="_blank"><img loading="lazy" src="%s" alt="%s"></a>' % (
                    esc(rel), esc(rel), esc(item.get("title")))
            full = item.get("full")
            if full is None:
                # 宽画面（左右并排的对比片）默认占满一整行，不然只有一列宽、看不清
                full = bool(size and size[0] and size[1] and size[0] / size[1] >= 2.2)
            length = '<span class="len">%.0f s</span>' % seconds if seconds else ""
            caption = "<b>%s%s</b>%s" % (esc(item.get("title")), length, esc(item.get("text")))
            if item.get("fact"):
                caption += '<div class="fact">%s</div>' % esc(item["fact"])
            if item.get("slow"):
                # 页面上放的是原速，慢放只给链接
                caption += '<div class="muted"><a href="%s" target="_blank">%s</a></div>' % (
                    esc(rel_to_page(item["slow"])), esc(slow_label(data.get("lang", "en"), item.get("slow_factor"))))
            parts.append("<figure%s>%s<figcaption>%s</figcaption></figure>" % (' class="full"' if full else "", media, caption))
            count += 1
        parts.append("</div>")
    parts.append("</main>\n</body>\n</html>\n")
    os.makedirs(out_dir, exist_ok=True)
    with open(output, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(parts))
    print(json.dumps({"output": output, "items": count}, ensure_ascii=False))


if __name__ == "__main__":
    main()
