#!/usr/bin/env python3
"""编译门（compile gate）的记录与检查。

auto-compile.sh 每次自动编译之后调 `record`，compile-gate-check.sh 每次改引擎源文件之前调 `check`。
门文件是 $QQ_TEMP_DIR/compile-gate-<session_id>，格式：

    第 1 行   <unix 时间戳>:<原因>
    其余各行  编译红灯期间仍然允许改的文件（项目根下的相对路径，正斜杠；Windows 上已转小写）

只有「定性的红」才立门：编译脚本退 1，并且输出里能找到落在项目里某个文件上的错误位置。
退 2（Editor 没开、超时、被拒绝）或退 1 却找不到错误位置（多半是工具链 / 环境问题，比如找不到 Godot、
dotnet）都不立门，也不动已有的门——没拿到裁决就当成红灯，项目里一改代码就被锁一小时，
而那时根本没有可修的编译错误。

红灯期间不是所有源文件都锁死：报错的文件和触发这次编译的那个文件仍然可以改。要修错误就得改代码，
全锁的话 agent 只能绕开 Edit 去改文件，门就形同虚设；而触发文件始终可改，至少总能把这次改动撤回去。
其余文件要等编译转绿（下一次自动编译通过，或手动跑 qq-compile.sh 通过）才放行，或者 1 小时后过期。

退出码：record 恒为 0（它只是记录，不能让钩子失败）；check 放行 0、拦截 3（拦截说明写到 stderr）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
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
_NOT_AN_ERROR = re.compile(r"^(warning|info|note|message)\b", re.IGNORECASE)


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

    for line in log.splitlines():
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
        for match in _GODOT_LOCATION.finditer(line):
            add(match.group("path"), line)
    return found


def _tail(log: str, lines: int) -> str:
    kept = [line for line in log.splitlines() if line.strip()]
    return "\n".join(kept[-lines:])


def _emit_context(message: str) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": message}}, ensure_ascii=False))


def cmd_record(args: argparse.Namespace) -> int:
    project = Path(args.project)
    gate = Path(args.gate_file) if args.gate_file else None
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
        allowed: list[str] = []
        trigger = gate_key(args.file, project) if args.file else None
        for key in [trigger, *(key for key, _ in locations)]:
            if key and key not in allowed:
                allowed.append(key)
        error_lines = "\n".join(line for _, line in locations[:20])
        if gate is not None:
            gate.write_text(f"{int(time.time())}:compile_failed\n" + "".join(f"{key}\n" for key in allowed), encoding="utf-8")
            listed = "\n".join(f"- {key}" for key in allowed)
            _emit_context(
                "⛔ [COMPILE-GATE 已激活] 编译失败。编译转绿之前，除下面这些文件外，对引擎源文件的 Edit/Write 都会被拒绝：\n"
                f"{listed}\n编译错误：\n{error_lines}\n"
                "先修这些文件里的错误（或者撤回刚才的改动）；下一次自动编译通过，或手动跑 qq-compile.sh 通过，门就解除。"
            )
        else:
            _emit_context(f"⛔ [auto-compile] 编译失败（没有会话 id，未立编译门）。编译错误：\n{error_lines}")
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
    gate = Path(args.gate_file)
    try:
        lines = gate.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return 0
    if not lines:
        return 0
    stamp, _, reason = lines[0].partition(":")
    try:
        age = time.time() - int(stamp)
    except ValueError:
        age = GATE_MAX_AGE_SECONDS + 1
    if age > GATE_MAX_AGE_SECONDS:
        gate.unlink(missing_ok=True)
        return 0

    project = Path(args.project)
    allowed = [line.strip() for line in lines[1:] if line.strip()]
    key = gate_key(args.file, project)
    if key is not None and key in allowed:
        return 0
    listed = "\n".join(f"  - {item}" for item in allowed) or "  （没有记录到报错文件）"
    print(
        f"⛔ BLOCKED: 上次自动编译失败（{reason or 'unknown'}），编译转绿之前只能改报错的文件和触发那次编译的文件：\n{listed}\n"
        f"先修这些文件里的错误，或者撤回触发编译的那次改动。如果错误已经在别处修好，运行 "
        f"qq-compile.sh --project \"{project}\" 复核，通过后本门自动解除。",
        file=sys.stderr,
    )
    return 3


def main() -> int:
    parser = argparse.ArgumentParser(description="qq compile gate: record auto-compile results / check edits")
    sub = parser.add_subparsers(dest="command", required=True)

    record = sub.add_parser("record", help="Record an auto-compile result (prints PostToolUse hook JSON)")
    record.add_argument("--project", required=True)
    record.add_argument("--gate-file", default="", help="Session gate file; empty = no session id, never write a gate")
    record.add_argument("--file", default="", help="The edited file that triggered the compile")
    record.add_argument("--exit-code", type=int, required=True)
    record.add_argument("--log", default="", help="File holding the compile output")

    check = sub.add_parser("check", help="Exit 3 (message on stderr) if the gate blocks editing --file")
    check.add_argument("--project", required=True)
    check.add_argument("--gate-file", required=True)
    check.add_argument("--file", required=True)

    args = parser.parse_args()
    if args.command == "record":
        return cmd_record(args)
    return cmd_check(args)


if __name__ == "__main__":
    sys.exit(main())
