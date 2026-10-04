#!/usr/bin/env python3
"""Unity 官方 CLI 通道（`unity command` / `unity job`）的读文件与判据助手。

分工：CLI 只在 bash 里调（scripts/unity-common.sh 的 qq_ucli*），本文件只读文件、只做判断，
**从不起子进程去跑 unity**——Windows 上 python 的 subprocess 跑不了没有扩展名的程序（WinError 2），
bash 可以；判据放在 python 里，是为了不让 bash 去碰 JSON。

安全：Library/Pipeline/.unity-pipeline-port（下称描述文件）里有一个令牌，拿到它就能在 Editor 里执行任意 C#。
本文件只按字段取 pid / port / projectPath 三个键，取完立刻丢掉整份内容；读不出来时只打印固定的原因词，
不打印原文、异常文本或 repr。别的脚本、技能也不要 cat / grep / sed 这个文件。

子命令（退出码各自说明）：
  probe               描述文件有效（读得出、属于本项目、pid 活着）→ stdout 一行 "<port> <pid>"，退 0；
                      否则退 1，stderr 只打一个原因词：missing | unreadable | foreign-project | pid-dead
  envelope            给 CLI 的 --json 信封分类：0 成功；10 busy 可重试（没执行）；11 network；12 超时；
                      13 弹窗挡住；14 作业不存在；2 其它失败。失败原因打到 stderr
  recompile-kind      recompile 的回包 → stdout compiling | up_to_date | unknown
  recompile-snapshot  记下调用前 Temp/pipeline_recompile_status.json 的 {status, failed, errors, mtime}
  snapshot-verdict    拿快照当裁决：只认 completed（0 成功 / 1 失败），其余退 2
  wait-recompile      等 Temp/pipeline_recompile_status.json 出现调用之后写下的 completed（0 / 1 / 超时 2）
  recompile-busy      快照表明调用前就有一次编译在途（compiling / triggered）：退 0；否则退 1
  settle-recompile    等在途的那次编译落地（状态文件不再是 compiling / triggered）：落地退 0，超时退 2
  newer-sources       有没有比参照时间新的 Unity 源文件（Unity 没看见的改动）：有退 0 并打印第一个，没有退 1
  test-in-flight      Temp/pipeline_test_request.json 表明有一轮测试在跑：退 0；没有退 1
  editor-status       读 editor_status 的回包 → stdout 一行（制表符分隔）：status compiling reload playMode owner

扩展：新的判据（例如测试结果）照下面的写法加一个 cmd_xxx 和一段 add_parser 即可。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time

DESCRIPTOR = ("Library", "Pipeline", ".unity-pipeline-port")
RECOMPILE_STATUS = ("Temp", "pipeline_recompile_status.json")
TEST_REQUEST = ("Temp", "pipeline_test_request.json")
TEST_STATUS = ("Temp", "pipeline_test_status.json")
# Unity 只编 Assets/ 和 Packages/ 下的这些文件；项目里其它地方的 .cs 不归它编
SOURCE_ROOTS = ("assets", "packages")
SOURCE_EXTS = (".cs", ".asmdef", ".asmref", ".rsp")
MAX_ERRORS_SHOWN = 20

EXIT_OK = 0
EXIT_OTHER = 2
EXIT_BUSY = 10
EXIT_NETWORK = 11
EXIT_TIMEOUT = 12
EXIT_DIALOG = 13
EXIT_JOB_NOT_FOUND = 14


def _utf8_stdio() -> None:
    # 测试名、错误信息里有中文；Windows 管道的默认编码不一定是 UTF-8
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", newline="\n")
        except (AttributeError, ValueError):
            pass


def _env_float(name: str, default: float) -> float:
    try:
        return max(0.0, float(os.environ.get(name, "")))
    except ValueError:
        return default


def _native(raw: str) -> str:
    """Git Bash 的 /c/x 写法在 Windows 的 python 里会被当成「当前盘根下的 c 目录」，先换成 C:/x。"""
    raw = raw.strip()
    if os.name == "nt":
        match = re.match(r"^/([A-Za-z])(/.*)?$", raw)
        if match:
            return f"{match.group(1)}:{match.group(2) or '/'}"
    return raw


def _norm(path: str) -> str:
    return os.path.normcase(os.path.abspath(_native(path))).rstrip("\\/")


def _same_path(a: str, b: str) -> bool:
    if _norm(a) == _norm(b):
        return True
    try:  # macOS 的大小写、Windows 的 junction / subst
        return os.path.exists(_native(a)) and os.path.exists(_native(b)) and os.path.samefile(_native(a), _native(b))
    except OSError:
        return False


def _project_file(project: str, parts: tuple) -> str:
    return os.path.join(_native(project), *parts)


def _read_json_file(path: str, retries: int = 3, delay: float = 0.1):
    """容错读 Editor 写的状态文件（不是描述文件）：可能正在写、是半截，重试几次。读不到返回 None。"""
    for attempt in range(retries):
        if attempt:
            time.sleep(delay)
        try:
            with open(path, "r", encoding="utf-8-sig") as handle:
                text = handle.read()
            if text.strip():
                return json.loads(text)
        except FileNotFoundError:
            return None
        except (OSError, ValueError):
            continue
    return None


def _mtime(path: str):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


# ── probe：描述文件 ──────────────────────────────────────────────────────────

def _descriptor_fields(path: str):
    """返回 (pid, port, projectPath)，或一个原因词。整份内容不离开这个函数，异常文本也不往外传。"""
    delay = _env_float("QQ_UNITY_PROBE_RETRY_DELAY", 0.2)
    for attempt in range(3):  # Editor 写描述文件不是原子的：读到空文件 / 半截 JSON 就隔一会儿再读
        if attempt:
            time.sleep(delay)
        if not os.path.isfile(path):
            return "missing"
        data = None
        try:
            with open(path, "r", encoding="utf-8-sig") as handle:
                data = json.loads(handle.read())
        except Exception:  # noqa: BLE001 —— 异常里可能带着原文片段，一律只当「这次没读成」
            data = None
            continue
        if not isinstance(data, dict):
            data = None
            continue
        fields = (data.get("pid"), data.get("port"), data.get("projectPath"))
        data = None
        return fields
    return "unreadable"


def pid_alive(pid: int) -> bool:
    if os.name == "nt":
        # 绝不能用 os.kill：Windows 上信号 0 就是 CTRL_C_EVENT，等于给目标发 Ctrl+C
        import ctypes
        from ctypes import wintypes

        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        k32.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        k32.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return ctypes.get_last_error() == 5  # ACCESS_DENIED：进程在，只是没权限
        try:
            code = wintypes.DWORD()
            if not k32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return True
            return code.value == 259  # STILL_ACTIVE
        finally:
            k32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def cmd_probe(args) -> int:
    fields = _descriptor_fields(_project_file(args.project, DESCRIPTOR))
    if isinstance(fields, str):
        print(fields, file=sys.stderr)
        return 1
    pid, port, owner = fields
    if type(pid) is not int or type(port) is not int or pid <= 0 or not 1 <= port <= 65535 \
            or not isinstance(owner, str) or not owner.strip():
        print("unreadable", file=sys.stderr)
        return 1
    if not _same_path(owner, args.project):  # 拷 Library 时把别的项目的描述文件带了过来
        print("foreign-project", file=sys.stderr)
        return 1
    if not pid_alive(pid):
        print("pid-dead", file=sys.stderr)
        return 1
    print(f"{port} {pid}")
    return 0


# ── envelope：CLI 信封 ────────────────────────────────────────────────────────

def _find_values(obj, key: str, depth: int = 4) -> list:
    found = []
    if depth < 0:
        return found
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                found.append(v)
            found.extend(_find_values(v, key, depth - 1))
    elif isinstance(obj, list):
        for item in obj:
            found.extend(_find_values(item, key, depth - 1))
    return found


def _errors_text(env: dict) -> str:
    parts = []
    errors = env.get("errors")
    if isinstance(errors, list):
        for item in errors:
            if isinstance(item, dict):
                text = ": ".join(str(item[k]) for k in ("code", "message") if item.get(k) not in (None, ""))
                parts.append(text or json.dumps(item, ensure_ascii=False)[:300])
            elif item not in (None, ""):
                parts.append(str(item))
    for key in ("message", "error"):
        value = env.get(key)
        if isinstance(value, str) and value:
            parts.append(value)
    return "; ".join(parts)


def classify_envelope(text: str, rc: int):
    """返回 (分类码, 原因)。只看信封（L0–L1），不碰 data.result 里的业务字段。"""
    if not text.strip():
        return EXIT_OTHER, f"L0 empty stdout (exit={rc})"
    try:
        env = json.loads(text)
    except ValueError:
        return EXIT_OTHER, f"L0 stdout is not JSON (exit={rc})"
    if not isinstance(env, dict):
        return EXIT_OTHER, f"L0 envelope is not an object (exit={rc})"

    if env.get("success") is True:  # 身份比较：字符串 "true"、1 都不算
        if rc != 0:  # 信封说成功、退出码说失败：协议破裂，哪一边都不信
            return EXIT_OTHER, f"L1 protocol break: success=true but exit={rc}"
        errors = env.get("errors")
        if errors is not None and not isinstance(errors, list):
            return EXIT_OTHER, "L1 errors is not a list"
        if errors:
            return EXIT_OTHER, f"L1 errors not empty: {_errors_text(env)}"
        if env.get("data") is None:
            return EXIT_OTHER, "L1 data is missing or null"
        return EXIT_OK, ""

    message = _errors_text(env) or "(no error message)"
    reason = f"exit={rc}: {message}"
    busy = [v for v in _find_values(env, "busyReason") if v]
    dialogs = [v for v in _find_values(env, "dialogs") if v]
    if dialogs or "blocked_by_dialog" in busy:
        detail = json.dumps(dialogs, ensure_ascii=False)[:600] if dialogs else ""
        return EXIT_DIALOG, f"{reason}; Unity is blocked by a modal dialog {detail}".rstrip()
    if any(value is True for value in _find_values(env, "retryable")):
        extra = f" (busyReason={busy[0]})" if busy else ""
        return EXIT_BUSY, f"{reason}{extra}"
    lowered = message.lower()
    if "timed out after" in lowered:
        return EXIT_TIMEOUT, reason
    if "network error" in lowered:
        return EXIT_NETWORK, reason
    if "job not found" in lowered:
        return EXIT_JOB_NOT_FOUND, reason
    return EXIT_OTHER, reason


def _read_text(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8-sig", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def cmd_envelope(args) -> int:
    code, reason = classify_envelope(_read_text(args.file), args.rc)
    if code != EXIT_OK and not args.quiet:
        label = f"{args.label} " if args.label else ""
        print(f"[unity-cli] {label}failed — {reason}", file=sys.stderr)
        if args.stderr_file and reason.startswith("L0"):
            tail = [line for line in _read_text(args.stderr_file).splitlines() if line.strip()][-5:]
            for line in tail:
                print(f"  {line[:300]}", file=sys.stderr)
    return code


def _result_obj(env: dict):
    """data.result：对象就直接用；字符串就再解一层（recompile_status / test_status 是双重编码）。"""
    data = env.get("data") if isinstance(env, dict) else None
    result = data.get("result") if isinstance(data, dict) else None
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except ValueError:
            return None
    return result if isinstance(result, dict) else None


def cmd_recompile_kind(args) -> int:
    env = _read_json_file(args.file, retries=1)
    result = _result_obj(env) if isinstance(env, dict) else None
    status = result.get("status") if result else None
    print(status if status in ("compiling", "up_to_date") else "unknown")
    return 0


# ── 编译状态文件 Temp/pipeline_recompile_status.json ─────────────────────────
# 由 Pipeline 包写：每次 recompile 先写 triggered；之后所有编译（不止我们触发的）开始写 compiling、
# 结束写 completed + failed + errors；没有要编的写 up_to_date（会把上一次的红灯记录盖掉）。

def _status_snapshot(path: str) -> dict:
    if not os.path.isfile(path):
        return {"exists": False}
    mtime = _mtime(path)
    data = _read_json_file(path)
    if not isinstance(data, dict):
        return {"exists": True, "readable": False, "mtime": mtime}
    return {
        "exists": True,
        "readable": True,
        "mtime": mtime,
        "status": data.get("status"),
        "failed": data.get("failed"),
        "errors": data.get("errors"),
    }


def _print_errors(errors) -> None:
    if not isinstance(errors, list):
        return
    for line in errors[:MAX_ERRORS_SHOWN]:
        print(f"  {line}")
    if len(errors) > MAX_ERRORS_SHOWN:
        print(f"  … (+{len(errors) - MAX_ERRORS_SHOWN} more)")


def _completed_verdict(snapshot: dict, where: str) -> int:
    failed = snapshot.get("failed")
    if failed is True:
        errors = snapshot.get("errors")
        count = len(errors) if isinstance(errors, list) else 0
        print(f"[unity-cli] ❌ Compilation failed ({where}; {count} error(s))")
        _print_errors(errors)
        return 1
    if failed is False:
        print(f"[unity-cli] ✅ Compilation successful ({where})")
        return 0
    print(f"[unity-cli] {where}: status=completed but 'failed' is not a boolean — verdict untrusted", file=sys.stderr)
    return 2


def cmd_recompile_snapshot(args) -> int:
    snapshot = _status_snapshot(_project_file(args.project, RECOMPILE_STATUS))
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle)
    return 0


def cmd_snapshot_verdict(args) -> int:
    snapshot = _read_json_file(args.snapshot, retries=1) or {}
    if snapshot.get("status") == "completed":
        return _completed_verdict(snapshot, "last compile before this recompile")
    print("[unity-cli] Unity reported up_to_date, and there is no trustworthy previous verdict "
          f"(Temp/pipeline_recompile_status.json was {snapshot.get('status') or 'absent'} before the call).", file=sys.stderr)
    print("[unity-cli] Trigger a compile in Unity once, or add Tools/compile_gate.py to the project.", file=sys.stderr)
    return 2


BUSY_RECOMPILE_STATES = ("compiling", "triggered")


def cmd_recompile_busy(args) -> int:
    snapshot = _read_json_file(args.snapshot, retries=1) or {}
    return 0 if snapshot.get("status") in BUSY_RECOMPILE_STATES else 1


def cmd_settle_recompile(args) -> int:
    # 只等它落地，不拿它当裁决：它开始时未必已经包含这次改动
    path = _project_file(args.project, RECOMPILE_STATUS)
    deadline = time.time() + args.timeout
    while True:
        snapshot = _status_snapshot(path)
        if not snapshot.get("exists") or (snapshot.get("readable") and snapshot.get("status") not in BUSY_RECOMPILE_STATES):
            return 0
        if time.time() >= deadline:
            return 2
        time.sleep(args.poll)


def cmd_wait_recompile(args) -> int:
    path = _project_file(args.project, RECOMPILE_STATUS)
    deadline = time.time() + args.timeout
    last = {}
    while True:
        snapshot = _status_snapshot(path)
        if snapshot.get("readable"):
            last = snapshot
            fresh = args.require_mtime_after is None or (snapshot.get("mtime") or 0) >= args.require_mtime_after
            if snapshot.get("status") == "completed" and fresh:
                return _completed_verdict(snapshot, "Temp/pipeline_recompile_status.json")
        if time.time() >= deadline:
            print(f"[unity-cli] Timed out after {args.timeout:g}s waiting for a compile that finished after the "
                  f"recompile call (status file: {last.get('status') or 'absent'})", file=sys.stderr)
            return 2
        time.sleep(args.poll)


# ── newer-sources：Unity 没看见的改动 ─────────────────────────────────────────
# 「这个文件归不归 Unity 编」要和 auto-compile 钩子的判断（qq_engine.py matches-source）一致：钩子编了、守卫却不认，
# 守卫就成了摆设。所以复用 qq_engine 的「在不在根下」（词法写法和 resolve 写法都比，Assets/ 里指向项目外的符号链接 /
# 目录联接也算项目里）和 Packages/manifest.json 里 file: 引用的本地包（可以在项目根外面，Unity 照样编）。

def _qq_engine():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import qq_engine  # noqa: E402 —— 与 auto-compile 钩子同一套「在不在项目里」的判断
    except ImportError:
        return None
    return qq_engine


def _source_name_ok(parts) -> bool:
    if not parts or not parts[-1].lower().endswith(SOURCE_EXTS):
        return False
    return not any(seg.startswith(".") or seg.endswith("~") for seg in parts)  # Unity 忽略的目录 / 文件


def _display(path: str, project: str) -> str:
    try:
        rel = os.path.relpath(path, project)
    except ValueError:  # Windows 上不同盘符
        rel = path
    return rel.replace("\\", "/")


def _package_roots(engine, project: str) -> list:
    if engine is None:
        return []
    from pathlib import Path

    try:
        return [str(root) for root in engine.unity_local_package_roots(Path(project))]
    except Exception:  # noqa: BLE001 —— manifest 读不出来就当没有本地包
        return []


def _unity_source(raw: str, project: str, engine, package_roots):
    """auto-compile 传来的改动文件 → (文件路径, 显示用的相对路径)；不归 Unity 编的返回 None。"""
    raw = raw.strip().strip("\"'")
    if not raw:
        return None
    path = _native(raw)
    if not os.path.isabs(path):
        path = os.path.join(project, path)
    if engine is None:
        # 只拷了一部分脚本、没有 qq_engine：信钩子的预过滤（它已经判过在项目里），只看扩展名
        parts = path.replace("\\", "/").split("/")
        return (path, _display(path, project)) if _source_name_ok(parts) else None
    from pathlib import Path

    for root in package_roots:  # 本地包里的文件不管放在哪都归 Unity 编
        token = engine._relative_token(Path(path), Path(root))
        if token is not None:
            return (path, _display(os.path.join(root, token), project)) if _source_name_ok(token.split("/")) else None
    token = engine._relative_token(Path(path), Path(project))
    if token is None:
        return None
    parts = token.split("/")
    # 项目里只有 Assets/、Packages/ 下的归 Unity 编（Tools/ 下的生成器之类不算）；显示用钩子给的原样大小写
    if len(parts) < 2 or parts[0].lower() not in SOURCE_ROOTS or not _source_name_ok(parts):
        return None
    return path, token


def _is_link(entry) -> bool:
    if entry.is_symlink():
        return True
    try:  # Windows 的目录联接不算 symlink；看 reparse point 属性（scandir 已经带回来了，不多一次系统调用）
        return bool(getattr(entry.stat(follow_symlinks=False), "st_file_attributes", 0) & 0x400)
    except OSError:
        return False


def _walk_newer(top: str, ref: float, seen: set):
    """在 top 下找第一个比 ref 新的 Unity 源文件。跟着符号链接 / 目录联接走（链进来的目录 Unity 一样编），
    链过去的真实目录记进 seen 防环。"""
    stack = [(top, 0)]
    while stack:
        directory, depth = stack.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError:
            continue
        for entry in entries:
            name = entry.name
            if name.startswith(".") or name.endswith("~"):
                continue
            try:
                if entry.is_dir():
                    if depth >= 64:
                        continue
                    if _is_link(entry):
                        key = os.path.normcase(os.path.realpath(entry.path))
                        if key in seen:
                            continue
                        seen.add(key)
                    stack.append((entry.path, depth + 1))
                elif name.lower().endswith(SOURCE_EXTS) and entry.stat().st_mtime > ref:
                    return entry.path
            except OSError:
                continue
    return None


def _scan_newer(project: str, ref: float, package_roots):
    try:
        tops = [os.path.join(project, top) for top in os.listdir(project) if top.lower() in SOURCE_ROOTS]
    except OSError:
        tops = []
    roots = tops + list(package_roots)
    seen = {os.path.normcase(os.path.realpath(root)) for root in roots}
    for root in roots:
        found = _walk_newer(root, ref, seen)
        if found:
            return _display(found, project)
    return None


_ISO_TIME = re.compile(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$")


def _iso_epoch(value):
    """compile_gate.json 的 startedAt（.NET 的 "o" 格式，小数 7 位、带时区）→ epoch 秒；解析不了返回 None。"""
    if not isinstance(value, str):
        return None
    match = _ISO_TIME.match(value.strip())
    if not match:
        return None
    import datetime

    date, clock, fraction, zone = match.groups()
    try:
        moment = datetime.datetime.strptime(f"{date}T{clock}", "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    seconds = float(fraction) if fraction else 0.0
    if zone in (None, ""):
        return time.mktime(moment.timetuple()) + seconds  # 不带时区 = 本机时间
    offset = 0
    if zone != "Z":
        sign = -1 if zone[0] == "-" else 1
        digits = zone[1:].replace(":", "")
        offset = sign * (int(digits[:2]) * 3600 + int(digits[2:]) * 60)
    return moment.replace(tzinfo=datetime.timezone.utc).timestamp() - offset + seconds


def _gate_reference(path: str, require_start: bool):
    """上一次编译的参照时间：优先用 compile_gate.json 的 startedAt（编译**开始**时间——编译途中改的文件它未必
    编进去了，拿结束时间比会漏掉）；没有这个字段时退回文件的 mtime（结束时间）。require_start 时不退：
    调用前就有一次编译在跑，它到底是在改动之前还是之后开始的，只有开始时间说得清。"""
    started = _iso_epoch((_read_json_file(path) or {}).get("startedAt"))
    if started is not None or require_start:
        return started
    return _mtime(path)


def cmd_newer_sources(args) -> int:
    ref = None
    if args.ref_mtime is not None:
        ref = args.ref_mtime
    elif args.ref_file:
        ref = _mtime(_native(args.ref_file))
    elif args.ref_gate_file:
        ref = _gate_reference(_native(args.ref_gate_file), args.require_start)
    elif args.ref_snapshot:
        ref = (_read_json_file(args.ref_snapshot, retries=1) or {}).get("mtime")
    if not isinstance(ref, (int, float)):
        # 没有参照时间就证明不了 Unity 看见了所有改动
        print("the start time of the last compile is unknown, so it may predate the change")
        return 0
    project = _native(args.project)
    engine = _qq_engine()
    package_roots = _package_roots(engine, project)
    changed = [line for value in (args.changed or []) for line in value.splitlines() if line.strip()]
    if changed:
        for raw in changed:
            hit = _unity_source(raw, project, engine, package_roots)
            if hit and (_mtime(hit[0]) or 0) > ref:
                print(f"{hit[1]} is newer than the last compile")
                return 0
        return 1
    newer = _scan_newer(project, ref, package_roots)
    if newer:
        print(f"{newer} is newer than the last compile")
        return 0
    return 1


# ── 测试在途 / editor_status ─────────────────────────────────────────────────

def cmd_test_in_flight(args) -> int:
    # PlayMode（以及所有异步）测试提交时写 request、删 status，跑完写 status、删 request。
    # request 在、status 不在或比 request 旧 ⇒ 有一轮在跑（任何客户端发起的都算）。
    request = _mtime(_project_file(args.project, TEST_REQUEST))
    if request is None:
        return 1
    status = _mtime(_project_file(args.project, TEST_STATUS))
    if status is not None and status >= request:
        return 1
    print("in-flight")
    return 0


def _flag(value) -> str:
    if value is True:
        return "true"
    if value is False:
        return "false"
    return "-"


def cmd_editor_status(args) -> int:
    env = _read_json_file(args.file, retries=1)
    result = _result_obj(env) if isinstance(env, dict) else None
    if result is None:
        print("[unity-cli] editor_status: data.result is not an object", file=sys.stderr)
        return 2
    owner = result.get("projectPath")
    if not isinstance(owner, str) or not owner:
        ownership = "unknown"
    elif args.project and _same_path(owner, args.project):
        ownership = "ok"
    else:
        ownership = "foreign" if args.project else "unknown"
    fields = [
        str(result.get("status") or "-"),
        _flag(result.get("compiling")),
        _flag(result.get("domainReloadInProgress")),
        str(result.get("playMode") or "-"),
        ownership,
    ]
    print("\t".join(field.replace("\t", " ") for field in fields))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Unity official CLI channel helpers (qq)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("probe", help="validate Library/Pipeline/.unity-pipeline-port (prints '<port> <pid>')")
    p.add_argument("--project", required=True)
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("envelope", help="classify a `unity --json` envelope")
    p.add_argument("--file", required=True)
    p.add_argument("--rc", type=int, required=True)
    p.add_argument("--stderr-file")
    p.add_argument("--label", default="")
    p.add_argument("--quiet", action="store_true")
    p.set_defaults(func=cmd_envelope)

    p = sub.add_parser("recompile-kind", help="compiling | up_to_date | unknown")
    p.add_argument("--file", required=True)
    p.set_defaults(func=cmd_recompile_kind)

    p = sub.add_parser("recompile-snapshot", help="record the recompile status file before triggering")
    p.add_argument("--project", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_recompile_snapshot)

    p = sub.add_parser("snapshot-verdict", help="verdict from the pre-trigger snapshot (completed only)")
    p.add_argument("--snapshot", required=True)
    p.set_defaults(func=cmd_snapshot_verdict)

    p = sub.add_parser("wait-recompile", help="wait for a completed compile in the recompile status file")
    p.add_argument("--project", required=True)
    p.add_argument("--timeout", type=float, default=15.0)
    p.add_argument("--poll", type=float, default=0.5)
    p.add_argument("--require-mtime-after", type=float, default=None)
    p.set_defaults(func=cmd_wait_recompile)

    p = sub.add_parser("recompile-busy", help="exit 0 if the snapshot shows a compile already in flight")
    p.add_argument("--snapshot", required=True)
    p.set_defaults(func=cmd_recompile_busy)

    p = sub.add_parser("settle-recompile", help="wait until the compile already in flight has finished")
    p.add_argument("--project", required=True)
    p.add_argument("--timeout", type=float, default=15.0)
    p.add_argument("--poll", type=float, default=0.5)
    p.set_defaults(func=cmd_settle_recompile)

    p = sub.add_parser("newer-sources", help="exit 0 if a Unity source file is newer than the last compile")
    p.add_argument("--project", required=True)
    ref = p.add_mutually_exclusive_group(required=True)
    ref.add_argument("--ref-mtime", type=float)
    ref.add_argument("--ref-file")
    ref.add_argument("--ref-gate-file", help="Temp/compile_gate.json: its startedAt, else its mtime")
    ref.add_argument("--ref-snapshot")
    p.add_argument("--require-start", action="store_true",
                   help="with --ref-gate-file: no startedAt means no reference (a compile was in flight before the call)")
    p.add_argument("--changed", action="append", help="only check these files (newline-separated lists allowed)")
    p.set_defaults(func=cmd_newer_sources)

    p = sub.add_parser("test-in-flight", help="exit 0 if Temp/pipeline_test_request.json shows a run in flight")
    p.add_argument("--project", required=True)
    p.set_defaults(func=cmd_test_in_flight)

    p = sub.add_parser("editor-status", help="summarize an editor_status envelope")
    p.add_argument("--file", required=True)
    p.add_argument("--project", default="")
    p.set_defaults(func=cmd_editor_status)
    return parser


def main(argv: list) -> int:
    _utf8_stdio()
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
