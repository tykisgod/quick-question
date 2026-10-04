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
  channel             给技能用的通道判断（unity-cli | tykit | none + 原因），与 unity-common.sh 的 qq_unity_channel 同一套判据

测试（unity-test.sh 的官方跑法；退出码 0 绿 / 1 红 / 2 没拿到可信裁决，失败时都写 --summary-out）：
  failure-category    CLI 调用失败时归到哪一类 failure_category（editor_not_detected / editor_busy / test_job_lost / …）
  test-config         规模下限（unity.min_tests.<mode>）和预期跳过名单的路径 → stdout "<最少条数>\\t<名单路径>"
  job-id              --detach 提交 run_tests 的回包 → stdout jobId
  job-poll            job status 的回包 → stdout "state\\t进度"；信封失败时退信封分类码（14 = 作业不存在）
  start-check         PlayMode 异步提交的回包：确认真的开跑了（result=running、Mode=PlayMode、FilterApplied 对得上）
  wait-playmode       等 Temp/pipeline_test_status.json 出现这次提交之后写下的终态
  verdict             测试判据 L0–L7（Protocol A = EditMode 作业，B = PlayMode 状态文件）
  note                没走到判据就失败时，记一份同样格式的摘要（failure_category、jobId）
  merge-summaries     把各模式的摘要合成 run record 的附加字段 → stdout "category\\ttotal\\tpassed\\tfailed\\tskipped\\tduration\\tnote"

扩展：新的判据照下面的写法加一个 cmd_xxx 和一段 add_parser 即可。
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


def _probe(project: str):
    """描述文件有效 → (port, pid)；否则返回一个原因词。"""
    fields = _descriptor_fields(_project_file(project, DESCRIPTOR))
    if isinstance(fields, str):
        return fields
    pid, port, owner = fields
    if type(pid) is not int or type(port) is not int or pid <= 0 or not 1 <= port <= 65535 \
            or not isinstance(owner, str) or not owner.strip():
        return "unreadable"
    if not _same_path(owner, project):  # 拷 Library 时把别的项目的描述文件带了过来
        return "foreign-project"
    if not pid_alive(pid):
        return "pid-dead"
    return port, pid


def cmd_probe(args) -> int:
    probed = _probe(args.project)
    if isinstance(probed, str):
        print(probed, file=sys.stderr)
        return 1
    print(f"{probed[0]} {probed[1]}")
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


# ── channel：给技能用的通道判断 ───────────────────────────────────────────────
# 权威判定在 unity-common.sh 的 qq_unity_channel（脚本真正走哪条路看它）；这里是同一套判据的只读版，
# 让技能在调脚本之前就知道该用哪种写法做健康检查。不发网络请求、不跑 unity --version。

_EDITOR_BINARY = re.compile(r"/Unity\.app/|/Editor/unity(\.exe)?$", re.I)


def _find_cli():
    candidate = os.environ.get("QQ_UNITY_CLI", "").strip()
    if not candidate:
        import shutil

        candidate = shutil.which("unity") or ""
    if not candidate or not os.path.exists(_native(candidate)):
        return None
    if _EDITOR_BINARY.search(candidate.replace("\\", "/")):  # PATH 上的 Unity Editor 本体不算 CLI
        return None
    return candidate


def _channel_without_cli(args) -> str:
    """描述文件有效、却找不到 CLI：项目还装着 tykit 就回落 tykit（描述文件出现之前它就是能用的通道），否则没有通道。"""
    if os.path.isfile(_project_file(args.project, ("Temp", "tykit.json"))):
        return "tykit\tunity_cli_unavailable (falling back to tykit)"
    return ("none" if args.kind == "test" else "refresh-trigger") + "\tunity_cli_unavailable"


def cmd_channel(args) -> int:
    forced = os.environ.get("QQ_UNITY_CHANNEL", "").strip()
    if forced in ("unity-cli", "tykit", "refresh-trigger", "none"):
        print(f"{forced}\tforced")
        return 0
    probed = _probe(args.project)
    if not isinstance(probed, str):
        print("unity-cli\tpipeline-descriptor" if _find_cli() else _channel_without_cli(args))
        return 0
    if os.path.isfile(_project_file(args.project, ("Temp", "tykit.json"))):
        print(f"tykit\ttykit-json (pipeline descriptor: {probed})")
        return 0
    print(("none\teditor_not_detected" if args.kind == "test" else "refresh-trigger\tno-channel") + f" (pipeline descriptor: {probed})")
    return 0


# ── 测试判据（unity-test.sh 的官方跑法）──────────────────────────────────────
# 照搬游戏仓 Tools/unity_cli/uc_lib.ps1 的 L0–L7 分层。实测过一次 1 过 1 败的运行：退出码、顶层 success、
# data.state、data.error、result.success 五个判据点全是绿的，只有 Summary.Failed 是 1 —— 所以一直读到
# Summary.Failed 和跳过数，退出码和任何 success 字段都只是必要条件。
#
#   L0–L1  信封（classify_envelope）                        失败 2 / unity_cli_transport
#   L2     作业层（仅 A）：command、jobId、state、error       失败 2 / unity_cli_transport
#   L3     内层 success（只有 run_tests / list_tests / menu 有） 失败 2 / test_run_error
#   L3b    请求身份：不是异步启动响应、Mode、FilterApplied     失败 2 / test_verdict_untrusted
#   L4     Summary 五个计数都是非负整数                       失败 2 / test_verdict_untrusted
#   L5     规模：Total=0、低于下限                            失败 1 / test_count_below_floor
#   L6     Results 结构与直方图（A 逐项相等，B 不超过）        失败 2 / test_verdict_untrusted
#   L7     Failed / Inconclusive / 名单外的 Skipped          失败 1 / test_failed

TEST_STATUSES = ("Passed", "Failed", "Skipped", "Inconclusive")
SUMMARY_KEYS = ("Total", "Passed", "Failed", "Skipped", "Inconclusive")
# 只有返回 CommandExecutionResponse 子类的命令才有内层 success（读包源码核实过）；get_console_logs 这类的
# data.result 根本没有这个字段，把 L3 当通用层会让它们全线假红
INNER_SUCCESS_COMMANDS = ("run_tests", "list_tests", "menu")
MAX_NAMED = 20  # run record 里的名单截到 20 条：附加字段走命令行，Windows 上命令行有 32K 上限
NAME_CHARS = 160
MESSAGE_CHARS = 160


class VerdictFail(Exception):
    """某一层没过。layer 写进摘要的 verdict_layer，category 是 run record 的 failure_category，code 是退出码。"""

    def __init__(self, layer: str, message: str, category: str = "test_verdict_untrusted", code: int = EXIT_OTHER):
        super().__init__(message)
        self.layer = layer
        self.category = category
        self.code = code


def _clip(value, limit: int) -> str:
    text = value if isinstance(value, str) else ("" if value is None else str(value))
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _first_line(value, limit: int = MESSAGE_CHARS) -> str:
    text = value.strip() if isinstance(value, str) else ""
    return _clip(text.splitlines()[0], limit) if text else ""


def strict(obj, key: str, layer: str, category: str = "test_verdict_untrusted"):
    """严格取：键缺失或值为 null 都判失败。只用于必然存在的字段，不许写成 .get(k, 默认值)。"""
    if not isinstance(obj, dict):
        raise VerdictFail(layer, f"expected an object when reading '{key}', got {type(obj).__name__}", category)
    if obj.get(key) is None:
        raise VerdictFail(layer, f"missing field '{key}'", category)
    return obj[key]


def nullable(obj, key: str, layer: str, category: str = "test_verdict_untrusted"):
    """容忍缺失取：键缺失与值为 null 同样处理。/api/exec 保留 null，旧版 /api/job 把 null 键整个丢掉，两种都要过。"""
    if not isinstance(obj, dict):
        raise VerdictFail(layer, f"expected an object when reading '{key}', got {type(obj).__name__}", category)
    return obj.get(key)


def strict_int(obj, key: str, layer: str) -> int:
    value = strict(obj, key, layer)
    if type(value) is not int or value < 0:  # bool 是 int 的子类，type(...) is int 才排除得掉
        raise VerdictFail(layer, f"'{key}' is not a non-negative integer ({_clip(repr(value), 40)})")
    return value


def expected_filter_applied(filter_value, filter_type):
    """服务端回显的 FilterApplied：没传 filter 时是 null，传了是 "<filter_type 小写>: <filter>"。"""
    if not filter_value:
        return None
    return f"{(filter_type or 'testName').lower()}: {filter_value}"


def same_filter_applied(got, want) -> bool:
    if want is None:
        return got is None
    if not isinstance(got, str):
        return False
    got_type, sep, got_value = got.partition(": ")
    want_type, _, want_value = want.partition(": ")
    return bool(sep) and got_type.lower() == want_type.lower() and got_value == want_value


def check_inner_success(result, command: str) -> None:
    """L3：只对 INNER_SUCCESS_COMMANDS 有意义。失败理由的字段名因命令而异（menu 只有 message），三个都取。"""
    if command not in INNER_SUCCESS_COMMANDS:
        raise VerdictFail("L3", f"internal error: '{command}' has no inner success field; do not judge it at L3",
                          "unity_cli_transport")
    if strict(result, "success", "L3", "test_run_error") is not True:
        why = next((value for value in (nullable(result, "error", "L3"), nullable(result, "message", "L3"),
                                        nullable(result, "errorDetails", "L3")) if value), "(the command gave no reason)")
        raise VerdictFail("L3", f"result.success is not true: {_clip(str(why), 300)}", "test_run_error")


class SkipListUnreadable(Exception):
    """预期跳过名单在、却读不出来。只有真要拿它比对跳过时才算数（没有跳过的运行不受影响）。"""


def load_expected_skips(path) -> list:
    """预期跳过名单：每行一个 NUnit FullName，# 开头是注释。文件不在 = 空表 = 任何跳过都判红（fail-closed）。
    编码：UTF-8（可带 BOM）；带 BOM 的 UTF-16 也认——Windows PowerShell 5.1 的 > 和 Out-File 默认就写这个。
    别的编码（中文系统上 Set-Content 写的 GBK 之类）认不出来，抛 SkipListUnreadable，不当成空表悄悄判红。"""
    if not path:
        return []
    try:
        with open(_native(path), "rb") as handle:
            raw = handle.read()
    except FileNotFoundError:
        return []
    except OSError as error:
        raise SkipListUnreadable(f"it cannot be read ({type(error).__name__})") from None
    encoding = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig"
    try:
        text = raw.decode(encoding)
    except UnicodeDecodeError:
        raise SkipListUnreadable("it is not UTF-8 (or UTF-16 with a BOM) text; save it as UTF-8") from None
    return [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]


def _new_report(mode: str, job_id: str = "") -> dict:
    return {
        "mode": mode,
        "job_id": job_id or None,
        "counts": None,
        "duration": 0.0,
        "code": 0,
        "category": "",
        "layer": "ok",
        "reason": "",
        "failed_tests": [],
        "skipped_tests": [],
        "lines": [],
    }


def _fail_into(report: dict, error: VerdictFail) -> dict:
    report.update(code=error.code, category=error.category, layer=error.layer, reason=str(error))
    return report


def judge_test_result(result, *, protocol: str, expect_mode: str, expect_filter_applied, min_tests: int,
                      allow_zero: bool = False, allow_skipped: bool = False, expected_skips=(),
                      skips_source: str = "", skips_error: str = "", report=None) -> dict:
    """L3b–L7。result 是 run_tests 的结果对象（Protocol B 是由状态文件转成的同样结构）。"""
    report = report if report is not None else _new_report(expect_mode)
    try:
        if allow_zero and min_tests != 0:
            raise VerdictFail("args", "--allow-zero must be combined with --min-tests 0", "invalid_arguments")

        # L3b 请求身份：异步启动响应混进来、参数被静默吞掉
        leftover = nullable(result, "result", "L3b")
        if leftover is not None:
            raise VerdictFail("L3b", f"result.result={_clip(repr(leftover), 60)}: this is an async start response, not a finished run")
        if nullable(result, "StatusPath", "L3b") is not None:
            raise VerdictFail("L3b", "StatusPath is set: this is an async start response, not a finished run")
        mode = strict(result, "Mode", "L3b")
        if mode != expect_mode:  # 传 --mode editor 回来的是 "EditMode"
            raise VerdictFail("L3b", f"Mode={_clip(repr(mode), 40)}, expected '{expect_mode}' (without --mode the run falls back to All)")
        applied = nullable(result, "FilterApplied", "L3b")
        if not same_filter_applied(applied, expect_filter_applied):
            raise VerdictFail("L3b", f"FilterApplied={_clip(repr(applied), 80)}, expected {expect_filter_applied!r} "
                                     "(the filter was dropped or changed on the way in)")

        # L4 Summary 结构。不检查 P+F+S+I==Total：包里 Total 本来就是这四项相加，恒为真
        summary = strict(result, "Summary", "L4")
        if not isinstance(summary, dict):
            raise VerdictFail("L4", "Summary is not an object")
        counts = {key: strict_int(summary, key, "L4") for key in SUMMARY_KEYS}
        report["counts"] = counts

        # L5 规模
        if counts["Total"] == 0 and not allow_zero:
            raise VerdictFail("L5", "Total=0: the filter matched no tests, or the suite did not run",
                              "test_count_below_floor", 1)
        if counts["Total"] < min_tests:
            raise VerdictFail("L5", f"Total={counts['Total']} is below the minimum of {min_tests} "
                                    "(a wrong filter, or tests were left out)", "test_count_below_floor", 1)

        # L6 结构一致性。A 逐项相等；B 只要求不超过 Summary：PlayMode 跨 domain reload 后重新挂上的收集器
        # 会漏掉一部分 Results（而 Summary 取自完整的根节点），那是 PlayMode 的常态
        items = strict(result, "Results", "L6")
        if not isinstance(items, list):
            raise VerdictFail("L6", "Results is not a list")
        histogram = dict.fromkeys(TEST_STATUSES, 0)
        for item in items:
            if not isinstance(item, dict):
                raise VerdictFail("L6", "Results contains a non-object entry")
            status = strict(item, "Status", "L6")
            if status not in histogram:
                raise VerdictFail("L6", f"unknown test Status {_clip(repr(status), 40)}")
            histogram[status] += 1
        for key in TEST_STATUSES:
            if protocol == "A" and histogram[key] != counts[key]:
                raise VerdictFail("L6", f"Results has {histogram[key]} {key} but Summary.{key}={counts[key]}")
            if protocol == "B" and histogram[key] > counts[key]:
                raise VerdictFail("L6", f"Results has {histogram[key]} {key}, more than Summary.{key}={counts[key]}")

        # L7 裁决：判红要点名，不然人还得再跑一遍才知道去看哪里
        def named(status: str) -> list:
            return [item for item in items if item.get("Status") == status]

        def entry(item: dict) -> dict:
            return {"name": _clip(item.get("FullName") or "(no FullName)", NAME_CHARS),
                    "message": _first_line(item.get("Message"))}

        failed = named("Failed")
        report["failed_tests"] = [entry(item) for item in failed[:MAX_NAMED]]
        skipped = named("Skipped")
        report["skipped_tests"] = [_clip(item.get("FullName") or "(no FullName)", NAME_CHARS) for item in skipped[:MAX_NAMED]]
        lines = report["lines"]
        if counts["Failed"] > 0:
            lines.append("Failed tests:")
            for item in failed:
                lines.append(f"  ✗ {item.get('FullName') or '(no FullName)'}")
                message = _first_line(item.get("Message"), 300)
                if message:
                    lines.append(f"      {message}")
            if len(failed) < counts["Failed"]:
                lines.append(f"  … {counts['Failed'] - len(failed)} more failed test(s) are not listed in Results")
            raise VerdictFail("L7", f"Failed={counts['Failed']}", "test_failed", 1)
        if counts["Inconclusive"] > 0:
            lines.append("Inconclusive tests:")
            lines.extend(f"  ? {item.get('FullName') or '(no FullName)'}" for item in named("Inconclusive"))
            raise VerdictFail("L7", f"Inconclusive={counts['Inconclusive']}", "test_failed", 1)
        if counts["Skipped"] > 0:
            if allow_skipped:
                lines.append(f"Skipped {counts['Skipped']} test(s) (--allow-skipped):")
                lines.extend(f"  - {item.get('FullName') or '(no FullName)'}" for item in skipped)
            else:
                # 放行的是具名名单，不是「反正有跳过」；名单不全时不比对
                if len(skipped) != counts["Skipped"]:
                    raise VerdictFail("L7", f"Skipped={counts['Skipped']} but Results name only {len(skipped)}: "
                                            "the list is incomplete, so it is not checked against the expected-skips list",
                                      "test_failed", 1)
                if skips_error:  # 名单读不出来：判不了这些跳过是不是预期的，不当成空表去判红
                    lines.append("Skipped tests (not checked: the expected-skips list is unreadable):")
                    lines.extend(f"  - {item.get('FullName') or '(no FullName)'}" for item in skipped)
                    raise VerdictFail("L7", f"Skipped={counts['Skipped']}, but the expected-skips list {skips_source} "
                                            f"is unreadable: {skips_error}", "config_error")
                allowed = set(expected_skips)
                unexpected = [item for item in skipped if item.get("FullName") not in allowed]
                listing = [f"  - {item.get('FullName') or '(no FullName)'}" + (
                    f"\n      {_first_line(item.get('Message'), 300)}" if _first_line(item.get("Message")) else "")
                    for item in (unexpected or skipped)]
                if unexpected:
                    lines.append(f"Skipped tests not in the expected-skips list ({skips_source or 'none configured'}):")
                    lines.extend(listing)
                    raise VerdictFail("L7", f"Skipped={counts['Skipped']}, {len(unexpected)} of them not in the expected-skips list",
                                      "test_failed", 1)
                lines.append(f"Skipped {counts['Skipped']} test(s), all in the expected-skips list:")
                lines.extend(listing)
    except VerdictFail as error:
        return _fail_into(report, error)
    return report


def _envelope_category(code: int, reason: str = "") -> str:
    if "no pipeline instance" in reason.lower():
        return "editor_not_detected"
    if code == EXIT_JOB_NOT_FOUND:
        return "test_job_lost"
    if code in (EXIT_BUSY, EXIT_TIMEOUT, EXIT_DIALOG):
        return "editor_busy"
    return "unity_cli_transport"


def _protocol_a_result(path: str, rc: int, job_id: str):
    """Protocol A（EditMode 作业）的 L0–L3：job wait 的回包 → (run_tests 的结果对象, 时长)。"""
    text = _read_text(path)
    code, reason = classify_envelope(text, rc)
    if code != EXIT_OK:
        raise VerdictFail("L1", f"job wait: {reason}", _envelope_category(code, reason))
    data = json.loads(text)["data"]
    transport = "unity_cli_transport"
    command = strict(data, "command", "L2", transport)
    if command != "run_tests":
        raise VerdictFail("L2", f"data.command={_clip(repr(command), 40)}, expected 'run_tests'", transport)
    got_job = strict(data, "jobId", "L2", transport)
    if got_job != job_id:
        raise VerdictFail("L2", f"data.jobId={_clip(repr(got_job), 80)} is not the submitted job '{job_id}'", transport)
    state = strict(data, "state", "L2", transport)
    error = nullable(data, "error", "L2", transport)
    if state != "completed":
        raise VerdictFail("L2", f"job state={_clip(repr(state), 40)}, expected 'completed'"
                                + (f": {_clip(str(error), 300)}" if error else ""), transport)
    if error is not None:
        raise VerdictFail("L2", f"data.error is set: {_clip(str(error), 300)}", transport)
    result = strict(data, "result", "L2", transport)
    if isinstance(result, str):  # 有的结果字段是双重编码的字符串
        try:
            result = json.loads(result)
        except ValueError:
            pass
    if not isinstance(result, dict):
        raise VerdictFail("L2", "data.result is not an object", transport)
    check_inner_success(result, "run_tests")
    duration = result.get("Duration")
    return result, float(duration) if isinstance(duration, (int, float)) and not isinstance(duration, bool) else 0.0


def _protocol_b_result(path: str, submitted_at, expect_filter_applied):
    """Protocol B（PlayMode 异步）：Temp/pipeline_test_status.json → 与 A 同样结构的结果对象。
    状态文件顶层和 summary 是小写键，results[] 的元素是 PascalCase；字段名是 status，不是 state。"""
    mtime = _mtime(path)
    if mtime is None:
        raise VerdictFail("B", "Temp/pipeline_test_status.json does not exist", "test_timeout_or_blocked")
    if submitted_at is not None and mtime < submitted_at - 2:
        raise VerdictFail("B", "Temp/pipeline_test_status.json is left over from an earlier run (written before this submission)")
    status = _read_json_file(path)
    if not isinstance(status, dict):
        raise VerdictFail("B", "Temp/pipeline_test_status.json is not a JSON object")
    state = strict(status, "status", "B")
    if state != "completed":
        message = nullable(status, "message", "B")
        raise VerdictFail("B", f"status={_clip(repr(state), 40)}" + (f": {_clip(str(message), 300)}" if message else ""),
                          "test_run_error")
    summary = strict(status, "summary", "B")
    if not isinstance(summary, dict):
        raise VerdictFail("B", "summary is not an object")
    results = nullable(status, "results", "B")
    view = {
        # 状态文件里没有这几个字段：异步启动响应那一层（result / StatusPath / FilterApplied）已由 start-check 核对过
        "result": None,
        "StatusPath": None,
        "Mode": "PlayMode",
        "FilterApplied": expect_filter_applied,
        # 只改键名不改语义：计数仍取自 summary（NUnit 根节点，权威）
        "Summary": {key: strict_int(summary, key.lower(), "B") for key in SUMMARY_KEYS},
        "Results": [] if results is None else results,
    }
    duration = status.get("duration")
    return view, float(duration) if isinstance(duration, (int, float)) and not isinstance(duration, bool) else 0.0


def _summary_payload(report: dict) -> dict:
    counts = report["counts"] or dict.fromkeys(SUMMARY_KEYS, 0)
    return {
        "mode": report["mode"],
        "job_id": report["job_id"],
        "total": counts["Total"],
        "passed": counts["Passed"],
        "failed": counts["Failed"],
        "skipped": counts["Skipped"],
        "inconclusive": counts["Inconclusive"],
        "duration_sec": round(float(report["duration"] or 0.0), 3),
        "verdict_layer": report["layer"],
        "failure_category": report["category"],
        "exit_code": report["code"],
        "reason": _clip(report["reason"], 300),
        "failed_tests": report["failed_tests"][:MAX_NAMED],
        "skipped_tests": report["skipped_tests"][:MAX_NAMED],
    }


def _write_summary(path, report: dict) -> None:
    if not path:
        return
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(_summary_payload(report), handle, ensure_ascii=False)


def _print_report(report: dict) -> None:
    counts = report["counts"]
    code = report["code"]
    if code == 0:
        print("✅ Tests passed")
    elif code == 1:
        print(f"❌ Tests failed ({report['layer']}: {report['reason']})")
    else:
        print(f"⚠️ {report['mode']} verdict untrusted ({report['layer']}): {report['reason']}")
    if counts is not None:
        # 和 tykit 路径同一个形状（tykit_bridge.py 的 TEST_SUMMARY_RE 认 Skipped 后面紧跟 Duration）
        print(f"Total: {counts['Total']}  Passed: {counts['Passed']}  Failed: {counts['Failed']}  "
              f"Skipped: {counts['Skipped']}  Duration: {float(report['duration'] or 0.0):.2f}s  "
              f"Inconclusive: {counts['Inconclusive']}")
    for line in report["lines"]:
        print(line)
    sys.stdout.flush()


def cmd_verdict(args) -> int:
    report = _new_report(args.mode, args.job_id or "")
    expect = expected_filter_applied(args.filter, args.filter_type)
    try:
        if args.protocol == "A":
            if not args.file or not args.job_id:
                raise VerdictFail("args", "Protocol A needs --file and --job-id", "invalid_arguments")
            result, report["duration"] = _protocol_a_result(args.file, args.rc, args.job_id)
        else:
            if not args.status_file:
                raise VerdictFail("args", "Protocol B needs --status-file", "invalid_arguments")
            result, report["duration"] = _protocol_b_result(args.status_file, args.submitted_at, expect)
    except VerdictFail as error:
        _fail_into(report, error)
    except (ValueError, KeyError, TypeError) as error:
        _fail_into(report, VerdictFail("L0", f"unreadable reply ({type(error).__name__})", "unity_cli_transport"))
    else:
        try:
            skips, skips_error = load_expected_skips(args.expected_skips), ""
        except SkipListUnreadable as error:
            skips, skips_error = [], str(error)
        judge_test_result(result, protocol=args.protocol, expect_mode=args.mode, expect_filter_applied=expect,
                          min_tests=args.min_tests, allow_zero=args.allow_zero, allow_skipped=args.allow_skipped,
                          expected_skips=skips, skips_source=args.expected_skips or "", skips_error=skips_error,
                          report=report)
    _print_report(report)
    _write_summary(args.summary_out, report)
    return report["code"]


def cmd_note(args) -> int:
    report = _new_report(args.mode, args.job_id or "")
    report.update(code=args.exit, category=args.category, layer=args.layer, reason=args.reason or "")
    _write_summary(args.out, report)
    return 0


def cmd_failure_category(args) -> int:
    code, reason = classify_envelope(_read_text(args.file), args.rc)
    print(_envelope_category(code, reason) if code != EXIT_OK else "unity_cli_transport")
    return 0


def _load_qq_yaml(path: str) -> dict:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from qq_internal_config import load_structured_file  # noqa: E402 —— 与 qq 其它工具读同一套 qq.yaml 语法
    from pathlib import Path

    payload = load_structured_file(Path(path))
    return payload if isinstance(payload, dict) else {}


def cmd_test_config(args) -> int:
    project = _native(args.project)
    config = {}
    qq_yaml = os.path.join(project, "qq.yaml")
    if os.path.isfile(qq_yaml):
        try:
            config = _load_qq_yaml(qq_yaml)
        except ImportError:
            print("[unity-cli] scripts/qq_internal_config.py is missing; qq.yaml test settings are not applied", file=sys.stderr)
        except Exception as error:  # noqa: BLE001 —— 配置写坏了要报出来：悄悄用默认值等于把规模下限降回 1
            print(f"[unity-cli] qq.yaml could not be read, so the test floor and expected skips are unknown: {error}", file=sys.stderr)
            return 2
    unity = config.get("unity") if isinstance(config.get("unity"), dict) else {}

    min_tests = 1
    floor = unity.get("min_tests")
    if floor is not None and not isinstance(floor, dict):
        print("[unity-cli] qq.yaml: unity.min_tests must be a mapping (editmode: N, playmode: N)", file=sys.stderr)
        return 2
    if isinstance(floor, dict) and not args.filtered:  # 下限只管全量；带 filter 的窄跑默认至少 1 条
        value = floor.get(args.mode.lower())
        if value is not None:
            if type(value) is not int or value < 0:
                print(f"[unity-cli] qq.yaml: unity.min_tests.{args.mode.lower()} must be a non-negative integer", file=sys.stderr)
                return 2
            min_tests = value

    skips = os.environ.get("QQ_UNITY_EXPECTED_SKIPS", "").strip()
    configured = unity.get("expected_skips")
    if not skips:
        if configured is None:
            skips = os.path.join(".qq", "unity-expected-skips.txt")
        elif isinstance(configured, str) and configured.strip():
            skips = configured.strip()
        else:
            print("[unity-cli] qq.yaml: unity.expected_skips must be a file path", file=sys.stderr)
            return 2
    skips = _native(skips)
    if not os.path.isabs(skips):
        skips = os.path.join(project, skips)
    print(f"{min_tests}\t{os.path.normpath(skips)}")
    return 0


def cmd_job_id(args) -> int:
    env = _read_json_file(args.file, retries=1)
    data = env.get("data") if isinstance(env, dict) else None
    job = data.get("jobId") if isinstance(data, dict) else None
    command = data.get("command") if isinstance(data, dict) else None
    # jobId 会回到 argv 和提示里：只收可打印、不含空白和引号的
    if isinstance(job, str) and 0 < len(job) <= 200 and command in (None, "run_tests") \
            and all(33 <= ord(ch) <= 126 and ch not in "\"'\\`$" for ch in job):
        print(job)
        return 0
    print("[unity-cli] the detached run_tests submission did not return a usable jobId", file=sys.stderr)
    return EXIT_OTHER


def cmd_job_poll(args) -> int:
    text = _read_text(args.file)
    code, reason = classify_envelope(text, args.rc)
    if code != EXIT_OK:
        print(f"[unity-cli] job status failed — {reason}", file=sys.stderr)
        return code
    data = json.loads(text).get("data")
    if not isinstance(data, dict):
        print("[unity-cli] job status: data is not an object", file=sys.stderr)
        return EXIT_OTHER
    if data.get("jobId") not in (None, args.job_id):
        print(f"[unity-cli] job status answered for another job ({_clip(str(data.get('jobId')), 80)})", file=sys.stderr)
        return EXIT_OTHER
    state = data.get("state")
    if not isinstance(state, str) or not state:
        print("[unity-cli] job status: no state", file=sys.stderr)
        return EXIT_OTHER
    progress = data.get("progress")
    detail = "-"
    if isinstance(progress, dict):
        parts = [str(progress.get("title") or "").strip()]
        if isinstance(progress.get("current"), int) and isinstance(progress.get("total"), int) and progress["total"] > 0:
            parts.append(f"{progress['current']}/{progress['total']}")
        detail = _clip(" ".join(part for part in parts if part).replace("\t", " "), 120) or "-"
    print(f"{state}\t{detail}")
    return 0


def cmd_start_check(args) -> int:
    report = _new_report("PlayMode")
    text = _read_text(args.file)
    code, reason = classify_envelope(text, args.rc)
    expect = expected_filter_applied(args.filter, args.filter_type)
    try:
        if code == EXIT_NETWORK:
            # 提交不重投；回包丢了时看 Unity 有没有记下这次请求（异步提交会写 Temp/pipeline_test_request.json）
            request = _mtime(_project_file(args.project, TEST_REQUEST))
            if request is not None and request >= args.submitted_at - 2:
                print("[unity-cli] The submission's reply was lost (network error), but Unity recorded the run request: "
                      "treating the PlayMode run as started.")
                return 0
            raise VerdictFail("start", f"submission failed — {reason}; Unity has no record of the run request",
                              "unity_cli_transport")
        if code != EXIT_OK:
            raise VerdictFail("start", f"submission failed — {reason}", _envelope_category(code, reason))
        result = _result_obj(json.loads(text))
        if result is None:
            raise VerdictFail("start", "data.result is not an object", "unity_cli_transport")
        check_inner_success(result, "run_tests")
        if nullable(result, "result", "start") != "running":
            raise VerdictFail("start", f"result.result={_clip(repr(result.get('result')), 60)}, expected 'running' "
                                       "(the run was not started asynchronously)")
        mode = strict(result, "Mode", "start")
        if mode != "PlayMode":
            raise VerdictFail("start", f"Mode={_clip(repr(mode), 40)}, expected 'PlayMode'")
        applied = nullable(result, "FilterApplied", "start")
        if not same_filter_applied(applied, expect):
            raise VerdictFail("start", f"FilterApplied={_clip(repr(applied), 80)}, expected {expect!r} "
                                       "(the filter was dropped or changed on the way in)")
    except VerdictFail as error:
        _fail_into(report, error)
        print(f"⚠️ PlayMode run not confirmed started ({error.layer}): {error}")
        _write_summary(args.summary_out, report)
        return error.code
    return 0


def cmd_wait_playmode(args) -> int:
    path = _project_file(args.project, TEST_STATUS)
    started = time.time()
    deadline = started + args.timeout
    next_note = started + 60
    stale = False
    while True:
        mtime = _mtime(path)
        if mtime is not None:
            if mtime >= args.submitted_at - 2:
                data = _read_json_file(path)  # 半截文件读不出来就等下一轮
                state = data.get("status") if isinstance(data, dict) else None
                if state == "completed":
                    return 0
                if state in ("error", "cancelled"):
                    report = _new_report("PlayMode")
                    message = data.get("message")
                    _fail_into(report, VerdictFail("B", f"status={state}" + (f": {_clip(str(message), 300)}" if message else ""),
                                                   "test_run_error"))
                    print(f"⚠️ PlayMode run ended with status={state}" + (f": {_clip(str(message), 300)}" if message else ""))
                    _write_summary(args.summary_out, report)
                    return EXIT_OTHER
            else:
                stale = True
        now = time.time()
        if now >= deadline:
            report = _new_report("PlayMode")
            _fail_into(report, VerdictFail("B-wait", f"no result after {args.timeout:g}s", "test_timeout_or_blocked"))
            print(f"⚠️ Timeout waiting ({args.timeout:g}s) for the PlayMode result in Temp/pipeline_test_status.json"
                  + (" (only a status file from an earlier run was there)" if stale else ""))
            print("   The run may still be going in Unity, or a modal dialog may be blocking it: look at the Unity window.")
            print("   PlayMode has no resume (the status file does not say which run wrote it): let this run finish, then re-run.")
            _write_summary(args.summary_out, report)
            return EXIT_OTHER
        if now >= next_note:
            print(f"[unity-cli] PlayMode tests still running ({int(now - started)}s)…")
            sys.stdout.flush()
            next_note = now + 60
        time.sleep(max(args.poll, 0.05))


def cmd_merge_summaries(args) -> int:
    runs = []
    for path in args.files:
        data = _read_json_file(path, retries=1) if os.path.isfile(path) else None
        if isinstance(data, dict):
            runs.append(data)

    def total(key):
        return sum(run.get(key) for run in runs if type(run.get(key)) is int)

    # 各模式的退出码合成一个：一轮确定判红（1）整次就是红，另一轮没拿到裁决（2）不能把已经确定的失败降成「没有裁决」
    # （unity-test.sh 的 all 也这么合）。category 取这个退出码对应的那一轮；没裁决的那一轮写进 note，不丢
    codes = [run.get("exit_code") for run in runs if type(run.get("exit_code")) is int]
    worst = 1 if 1 in codes else max(codes or [0])
    category = args.category or next((str(run.get("failure_category") or "") for run in runs
                                      if run.get("exit_code") == worst and worst != 0), "")
    note = "; ".join(f"{run.get('mode')} gave no verdict ({run.get('failure_category') or 'unknown'})"
                     for run in runs if worst == 1 and run.get("exit_code") == EXIT_OTHER)
    duration = round(sum(float(run.get("duration_sec") or 0.0) for run in runs
                         if isinstance(run.get("duration_sec"), (int, float))), 3)
    extra = {
        "backend": args.backend,
        "transport": args.transport,
        "channel": "unity-cli",
        "mode": args.mode,
        "total": total("total"),
        "passed": total("passed"),
        "failed": total("failed"),
        "skipped": total("skipped"),
        "inconclusive": total("inconclusive"),
        "duration_sec": duration,
        "runs": runs,
    }
    job = next((run.get("job_id") for run in runs if run.get("job_id")), None)
    if job:
        extra["job_id"] = job
    with open(args.extra_out, "w", encoding="utf-8") as handle:
        json.dump(extra, handle, ensure_ascii=False)
    fields = (category or "-", extra["total"], extra["passed"], extra["failed"], extra["skipped"], duration, note or "-")
    print("\t".join(str(value).replace("\t", " ") for value in fields))
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

    p = sub.add_parser("channel", help="which Editor channel the project uses (for skills; scripts decide in bash)")
    p.add_argument("--project", required=True)
    p.add_argument("--kind", choices=("test", "compile"), default="test")
    p.set_defaults(func=cmd_channel)

    # 测试：带值的参数在 bash 里一律写成 --x=值（filter 可能以 - 开头）
    modes = ("EditMode", "PlayMode")
    p = sub.add_parser("failure-category", help="failure_category for a failed CLI call")
    p.add_argument("--file", required=True)
    p.add_argument("--rc", type=int, required=True)
    p.set_defaults(func=cmd_failure_category)

    p = sub.add_parser("test-config", help="test floor and expected-skips path from qq.yaml")
    p.add_argument("--project", required=True)
    p.add_argument("--mode", choices=modes, required=True)
    p.add_argument("--filtered", action="store_true", help="a filter was given: unity.min_tests does not apply")
    p.set_defaults(func=cmd_test_config)

    p = sub.add_parser("job-id", help="jobId from a --detach run_tests reply")
    p.add_argument("--file", required=True)
    p.set_defaults(func=cmd_job_id)

    p = sub.add_parser("job-poll", help="state of a detached job from a `unity job status` reply")
    p.add_argument("--file", required=True)
    p.add_argument("--rc", type=int, required=True)
    p.add_argument("--job-id", required=True)
    p.set_defaults(func=cmd_job_poll)

    p = sub.add_parser("start-check", help="confirm an async PlayMode run_tests really started")
    p.add_argument("--file", required=True)
    p.add_argument("--rc", type=int, required=True)
    p.add_argument("--project", required=True)
    p.add_argument("--submitted-at", type=float, required=True)
    p.add_argument("--filter", default="")
    p.add_argument("--filter-type", default="")
    p.add_argument("--summary-out")
    p.set_defaults(func=cmd_start_check)

    p = sub.add_parser("wait-playmode", help="wait for the PlayMode status file written after the submission")
    p.add_argument("--project", required=True)
    p.add_argument("--submitted-at", type=float, required=True)
    p.add_argument("--timeout", type=float, required=True)
    p.add_argument("--poll", type=float, default=5.0)
    p.add_argument("--summary-out")
    p.set_defaults(func=cmd_wait_playmode)

    p = sub.add_parser("verdict", help="L0-L7 test verdict (exit 0 green / 1 red / 2 untrusted)")
    p.add_argument("--protocol", choices=("A", "B"), required=True)
    p.add_argument("--file", help="A: `unity job wait` reply")
    p.add_argument("--rc", type=int, default=0, help="A: exit code of `unity job wait`")
    p.add_argument("--job-id", default="")
    p.add_argument("--status-file", help="B: Temp/pipeline_test_status.json")
    p.add_argument("--submitted-at", type=float, default=None)
    p.add_argument("--mode", choices=modes, required=True)
    p.add_argument("--filter", default="")
    p.add_argument("--filter-type", default="")
    p.add_argument("--min-tests", type=int, default=1)
    p.add_argument("--allow-zero", action="store_true")
    p.add_argument("--allow-skipped", action="store_true")
    p.add_argument("--expected-skips", default="")
    p.add_argument("--summary-out")
    p.set_defaults(func=cmd_verdict)

    p = sub.add_parser("note", help="record a summary for a run that never reached the verdict")
    p.add_argument("--out", required=True)
    p.add_argument("--mode", choices=modes, required=True)
    p.add_argument("--exit", type=int, required=True)
    p.add_argument("--category", required=True)
    p.add_argument("--layer", required=True)
    p.add_argument("--job-id", default="")
    p.add_argument("--reason", default="")
    p.set_defaults(func=cmd_note)

    p = sub.add_parser("merge-summaries", help="run-record extra fields from the per-mode summaries")
    p.add_argument("files", nargs="*")
    p.add_argument("--mode", required=True)
    p.add_argument("--backend", default="unity-cli")
    p.add_argument("--transport", default="unity-cli")
    p.add_argument("--category", default="")
    p.add_argument("--extra-out", required=True)
    p.set_defaults(func=cmd_merge_summaries)
    return parser


def main(argv: list) -> int:
    _utf8_stdio()
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except Exception as error:  # noqa: BLE001
        # 助手自己崩了 = 没拿到可信的答案，退 2：python 默认带着 traceback 退 1，unity-test.sh 会把它读成「测试红」。
        # 只打异常的类型，不打内容（probe 的异常里可能带着描述文件的片段）
        print(f"[unity-cli] {args.cmd}: internal error ({type(error).__name__}); no trustworthy answer", file=sys.stderr)
        summary_out = getattr(args, "summary_out", None)
        if summary_out:
            mode = args.mode if getattr(args, "mode", None) in ("EditMode", "PlayMode") else "PlayMode"
            report = _fail_into(_new_report(mode, getattr(args, "job_id", "") or ""),
                                VerdictFail("crash", f"internal error in {args.cmd} ({type(error).__name__})"))
            try:
                _write_summary(summary_out, report)
            except Exception:  # noqa: BLE001 —— 摘要也写不出来就算了，退出码已经说明了
                pass
        return EXIT_OTHER


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
