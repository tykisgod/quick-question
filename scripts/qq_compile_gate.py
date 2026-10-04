#!/usr/bin/env python3
"""编译门（compile gate）的记录、检查与清除。

auto-compile.sh 每次自动编译之后调 `record`，compile-gate-check.sh 每次改引擎源文件之前调 `check`，
qq-compile.sh 手动编译转绿时调 `clear`。

门文件按「会话 + 项目」区分：<前缀>-<项目根的短哈希>，前缀是 $QQ_TEMP_DIR/compile-gate-<session_id>。
同一会话里的 worktree / 别的项目各有各的门：一边红不会挡住另一边，一边绿也不会替另一边解门。
（子 agent 与主会话共用 session_id；同一棵树里并行的子 agent 共用一扇门——它们本来就共用同一份编译结果。）
门文件格式：

    第 1 行   <unix 时间戳>:<原因>
    其余各行  编译红灯期间仍然允许改的文件（项目根下的相对路径，正斜杠；Windows 上已转小写）

只有「定性的红」才立门：编译脚本退 1，并且输出里能找到落在项目里某个文件上的错误位置。
退 2（Editor 没开、超时、被拒绝）或退 1 却找不到错误位置（多半是工具链 / 环境问题，比如找不到 Godot、
dotnet）都不立门，也不动已有的门——没拿到裁决就当成红灯，项目里一改代码就被锁一小时，
而那时根本没有可修的编译错误。

红灯期间不是所有源文件都锁死，这些仍然可以改：
  - 报错的文件、触发编译的文件——一路红下去时逐次累积，不覆盖（改完 A 再改 B，A 仍可撤回）；
  - 错误信息里点名的类型所在的文件（'Service' does not contain a definition for 'Foo' → Service.cs）；
  - 还不存在的新文件（缺类型的错误往往就靠新建文件修好）；
  - 项目外的文件。
要修错误就得改代码，全锁的话 agent 只能绕开 Edit 去改文件，门就形同虚设。
其余已有的源文件等编译转绿（下一次自动编译通过，或手动跑 qq-compile.sh 通过）才放行，或者 1 小时后过期。

退出码：record / clear 恒为 0（只是记录，不能让钩子失败）；check 放行 0、拦截 3（拦截说明写到 stderr）。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

GATE_MAX_AGE_SECONDS = 3600
SOURCE_EXTENSIONS = ("cs", "cpp", "cc", "cxx", "c", "h", "hpp", "hh", "inl", "gd", "gdshader", "gdshaderinc", "razor")
_EXT = "|".join(SOURCE_EXTENSIONS)

# path(line[,col][,...]): …        —— C# / Unity / dotnet / MSVC（Unreal）
_PAREN_LOCATION = re.compile(r"(?P<path>[^\s\"'<>|?*(]+?\.(?:" + _EXT + r"))\((?P<line>\d+)(?:,\d+)*\)\s*:\s*(?P<rest>.*)", re.IGNORECASE)
# 同上，但允许路径里带空格（只认整行以路径开头的写法，免得把前缀文字吞进路径）
_PAREN_LOCATION_SPACED = re.compile(r"^\s*(?P<path>[^\"'<>|?*(]+?\.(?:" + _EXT + r"))\((?P<line>\d+)(?:,\d+)*\)\s*:\s*(?P<rest>.*)", re.IGNORECASE)
# path:line[:col]: error …         —— gcc / clang
_COLON_LOCATION = re.compile(r"(?P<path>[^\s\"'<>|?*(]+?\.(?:" + _EXT + r")):(?P<line>\d+)(?::\d+)?:\s*(?:fatal\s+)?error\b(?P<rest>.*)", re.IGNORECASE)
# res://path.gd[:line]              —— Godot（错误行与 "at: … (res://x.gd:12)" 行分开打印，所以只认路径）
_GODOT_LOCATION = re.compile(r"res://(?P<path>[^\s\"'<>|?*():]+\.(?:" + _EXT + r"))", re.IGNORECASE)
# Godot 的告警块：WARNING 开头的一行加上后面缩进的 "at:" 行；里面的 res:// 路径不算错误位置
_GODOT_BLOCK_HEADER = re.compile(r"^\s*(?:USER\s+|SCRIPT\s+)?(WARNING|ERROR)\b", re.IGNORECASE)
_GODOT_BLOCK_CONTINUATION = re.compile(r"^\s+at:", re.IGNORECASE)
_NOT_AN_ERROR = re.compile(r"^(warning|info|note|message)\b", re.IGNORECASE)
# 错误信息里用引号点名的标识符：'Service' does not contain a definition for 'Foo'
_QUOTED_IDENTIFIER = re.compile(r"['\"‘’`]([A-Za-z_][A-Za-z0-9_]*)['\"‘’`]")
# 没有 git 时自己遍历项目，跳过这些体积大、不放源码的目录
_SKIP_DIRS = {
    "library", "temp", "logs", "obj", "bin", "build", "builds", "usersettings", "packagecache",
    "intermediate", "saved", "deriveddatacache", "binaries", "node_modules",
}
_WALK_LIMIT = 200_000


def _msys_to_windows(raw: str) -> str:
    # Git Bash 风格的 /c/Users/… 在 Windows 的 python 里会被当成「当前盘根下的 c 目录」
    if os.name == "nt":
        match = re.match(r"^/([A-Za-z])/(.*)$", raw)
        if match:
            return f"{match.group(1)}:/{match.group(2)}"
    return raw


def _real(path: str) -> str:
    return os.path.normcase(os.path.realpath(os.path.abspath(path)))


def _absolute(raw: str, project: Path) -> str:
    """相对路径按项目根解释；反斜杠、Git Bash 的 /c/… 写法都先归一。"""
    raw = _msys_to_windows(raw.strip().strip("\"'").replace("\\", "/"))
    return raw if os.path.isabs(raw) else os.path.join(str(project), raw)


def gate_key(raw: str, project: Path) -> str | None:
    """把一个文件路径换成门文件里用的键：项目根下的相对路径、正斜杠、按平台规则归一大小写。
    不在项目里（含 .. 跳出去的）返回 None。"""
    if not raw.strip().strip("\"'"):
        return None
    candidate = _absolute(raw, project)
    root = _real(str(project))
    target = _real(candidate)
    try:
        rel = os.path.relpath(target, root)
    except ValueError:  # Windows 上不同盘符
        return None
    if rel == os.curdir or rel == os.pardir or rel.startswith(os.pardir + os.sep) or os.path.isabs(rel):
        return None
    return rel.replace(os.sep, "/")


def gate_path(prefix: str, project: Path) -> Path:
    """<前缀>-<项目根短哈希>。项目根先归一（盘符大小写、/c/ 写法、符号链接），钩子拿到的 C:/… 与
    qq-compile.sh 自己 pwd 出来的 /c/… 落到同一个文件。"""
    digest = hashlib.sha1(_real(_msys_to_windows(str(project).replace("\\", "/"))).encode("utf-8")).hexdigest()[:12]
    return Path(f"{prefix}-{digest}")


def error_locations(log: str, project: Path) -> list[tuple[str, str]]:
    """从编译输出里找落在项目文件上的错误位置。返回 [(键, 那一行)]，按出现顺序去重。
    只收真实存在于项目里的文件：路径前后粘着别的文字时宁可漏掉，也不立一个指向不存在文件的门。"""
    found: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add(path: str, line: str) -> bool:
        key = gate_key(path, project)
        if key is None or key in seen or not os.path.isfile(_absolute(path, project)):
            return False
        seen.add(key)
        found.append((key, line.strip()))
        return True

    in_godot_warning = False
    for line in log.splitlines():
        header = _GODOT_BLOCK_HEADER.match(line)
        if header:
            in_godot_warning = header.group(1).upper() == "WARNING"
        elif not _GODOT_BLOCK_CONTINUATION.match(line):
            in_godot_warning = False

        hit = False
        for pattern in (_PAREN_LOCATION_SPACED, _PAREN_LOCATION):
            for match in pattern.finditer(line):
                if _NOT_AN_ERROR.match(match.group("rest").strip()):
                    continue
                if add(match.group("path"), line):
                    hit = True
                    break
            if hit:
                break
        if hit:
            continue
        match = _COLON_LOCATION.search(line)
        if match and add(match.group("path"), line):
            continue
        if in_godot_warning:
            continue
        for match in _GODOT_LOCATION.finditer(line):
            add(match.group("path"), line)
    return found


def _project_sources(project: Path) -> list[str]:
    """项目里的源文件（键的形式）。优先 git ls-files（快，且按 .gitignore 跳过 Library 之类）；不是 git 仓库时自己遍历。"""
    patterns = [f"*.{ext}" for ext in SOURCE_EXTENSIONS]
    try:
        result = subprocess.run(
            ["git", "-C", str(project), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *patterns],
            capture_output=True, timeout=30, check=False,
        )
        if result.returncode == 0:
            return [os.path.normcase(item.decode("utf-8", "replace")).replace("\\", "/")
                    for item in result.stdout.split(b"\0") if item]
    except (OSError, subprocess.SubprocessError):
        pass
    found: list[str] = []
    visited = 0
    for root, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d.lower() not in _SKIP_DIRS]
        for name in files:
            visited += 1
            if visited > _WALK_LIMIT:
                return found
            if name.rsplit(".", 1)[-1].lower() in SOURCE_EXTENSIONS:
                rel = os.path.relpath(os.path.join(root, name), str(project))
                found.append(os.path.normcase(rel).replace(os.sep, "/"))
    return found


def named_type_files(error_lines: list[str], project: Path, already: set[str]) -> list[str]:
    """错误信息里用引号点名的类型所在的文件（按「文件名 = 类型名」找；Unity 的 MonoBehaviour 必须如此）。
    'Service' does not contain a definition for 'Foo' 要修的往往是 Service.cs，而它本身不报错。"""
    names = {match.group(1).lower() for line in error_lines for match in _QUOTED_IDENTIFIER.finditer(line)}
    if not names:
        return []
    files: list[str] = []
    for key in _project_sources(project):
        stem = key.rsplit("/", 1)[-1].split(".", 1)[0].lower()
        if stem in names and key not in already and key not in files:
            files.append(key)
    return files


def _read_gate(gate: Path) -> tuple[float | None, str, list[str]]:
    """(时间戳, 原因, 放行名单)；读不到或格式不对时时间戳为 None。"""
    try:
        lines = gate.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None, "", []
    if not lines:
        return None, "", []
    stamp, _, reason = lines[0].partition(":")
    try:
        ts = float(int(stamp))
    except ValueError:
        ts = None
    return ts, reason, [line.strip() for line in lines[1:] if line.strip()]


def _tail(log: str, lines: int) -> str:
    kept = [line for line in log.splitlines() if line.strip()]
    return "\n".join(kept[-lines:])


def _emit_context(message: str) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": message}}, ensure_ascii=False))


def cmd_record(args: argparse.Namespace) -> int:
    project = Path(args.project)
    gate = gate_path(args.gate_prefix, project) if args.gate_prefix else None
    try:
        log = Path(args.log).read_text(encoding="utf-8", errors="replace") if args.log else ""
    except OSError:
        log = ""

    if args.exit_code == 0:
        if gate is not None:
            gate.unlink(missing_ok=True)
        return 0

    locations = error_locations(log, project) if args.exit_code == 1 else []
    if args.exit_code == 1 and locations:
        error_lines = [line for _, line in locations]
        shown = "\n".join(error_lines[:20])
        if gate is None:
            _emit_context(f"⛔ [auto-compile] 编译失败（编译门没开或没有会话 id，没有立门）。编译错误：\n{shown}")
            return 0
        allowed: list[str] = []
        ts, _, previous = _read_gate(gate)
        if ts is not None and time.time() - ts <= GATE_MAX_AGE_SECONDS:
            allowed.extend(previous)   # 一路红下去时累积：之前的触发文件、报错文件仍可改（也就仍可撤回）
        trigger = gate_key(args.file, project) if args.file else None
        for key in [trigger, *(key for key, _ in locations)]:
            if key and key not in allowed:
                allowed.append(key)
        named = named_type_files(error_lines, project, set(allowed))
        allowed.extend(named)
        gate.write_text(f"{int(time.time())}:compile_failed\n" + "".join(f"{key}\n" for key in allowed), encoding="utf-8")
        listed = "\n".join(f"- {key}" for key in allowed)
        _emit_context(
            "⛔ [COMPILE-GATE 已激活] 编译失败。编译转绿之前，项目里已有的引擎源文件只有下面这些还能改"
            "（报错的文件、触发编译的文件、错误里点名的类型所在的文件），新建文件不受限：\n"
            f"{listed}\n编译错误：\n{shown}\n"
            "先修这些错误（或者撤回刚才的改动）；下一次自动编译通过，或手动跑 qq-compile.sh 通过，门就解除。"
        )
        return 0

    if args.exit_code == 1:
        _emit_context(
            "⚠️ [auto-compile] 编译脚本退 1，但输出里找不到落在项目文件上的错误位置（多半是工具链或环境问题），"
            f"编译门没有变化。输出末尾：\n{_tail(log, 12)}"
        )
    else:
        _emit_context(
            f"⚠️ [auto-compile] 没拿到编译裁决（exit {args.exit_code}：Editor 没开、超时或被拒绝），这次改动还没被编译器看过，"
            f"编译门没有变化。输出末尾：\n{_tail(log, 8)}"
        )
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    project = Path(args.project)
    gate = gate_path(args.gate_prefix, project)
    if not gate.is_file():
        return 0
    ts, reason, allowed = _read_gate(gate)
    if ts is None or time.time() - ts > GATE_MAX_AGE_SECONDS:
        gate.unlink(missing_ok=True)
        return 0

    key = gate_key(args.file, project)
    if key is None:   # 项目外的文件不归这个项目的门管
        return 0
    if key in allowed:
        return 0
    if not os.path.lexists(_absolute(args.file, project)):   # 新建文件：缺类型的错误常靠它修好，也掩盖不了已有的错误
        return 0
    listed = "\n".join(f"  - {item}" for item in allowed) or "  （没有记录到报错文件）"
    print(
        f"⛔ BLOCKED: 上次自动编译失败（{reason or 'unknown'}），编译转绿之前项目里已有的源文件只能改这些（新建文件不受限）：\n{listed}\n"
        f"先修这些文件里的错误，或者撤回触发编译的那次改动。如果错误已经在别处修好，运行 "
        f"qq-compile.sh --project \"{project}\" 复核，通过后本门自动解除。",
        file=sys.stderr,
    )
    return 3


def cmd_clear(args: argparse.Namespace) -> int:
    gate_path(args.gate_prefix, Path(args.project)).unlink(missing_ok=True)
    return 0


def main() -> int:
    # 输出里有 ⛔ ⚠️ 和中文。Windows 上 python 写管道默认用 ANSI 代码页（cp936 / cp1252），编不了这些字符会直接抛错，
    # 钩子的 JSON 就送不到模型；Claude Code 按 UTF-8 读钩子输出，这里统一改成 UTF-8。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass

    parser = argparse.ArgumentParser(description="qq compile gate: record auto-compile results / check edits / clear")
    sub = parser.add_subparsers(dest="command", required=True)

    record = sub.add_parser("record", help="Record an auto-compile result (prints PostToolUse hook JSON)")
    record.add_argument("--project", required=True)
    record.add_argument("--gate-prefix", default="",
                        help="$QQ_TEMP_DIR/compile-gate-<session_id>; empty = no session id or compile_gate disabled, never write a gate")
    record.add_argument("--file", default="", help="The edited file that triggered the compile")
    record.add_argument("--exit-code", type=int, required=True)
    record.add_argument("--log", default="", help="File holding the compile output")

    check = sub.add_parser("check", help="Exit 3 (message on stderr) if the gate blocks editing --file")
    check.add_argument("--project", required=True)
    check.add_argument("--gate-prefix", required=True)
    check.add_argument("--file", required=True)

    clear = sub.add_parser("clear", help="Remove this project's gate for the session")
    clear.add_argument("--project", required=True)
    clear.add_argument("--gate-prefix", required=True)

    args = parser.parse_args()
    if args.command == "record":
        return cmd_record(args)
    if args.command == "clear":
        return cmd_clear(args)
    return cmd_check(args)


if __name__ == "__main__":
    sys.exit(main())
