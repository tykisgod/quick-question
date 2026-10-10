#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, NoReturn

from qq_engine import (
    default_enabled_rules as engine_default_enabled_rules,
    default_test_scope as engine_default_test_scope,
    known_engines,
    normalize_engine_id,
    resolve_project_engine,
)


WORK_MODE_ALIASES = {
    "release": "hardening",
}

TRUST_LEVELS: dict[str, dict[str, Any]] = {
    "trusted": {
        "description": "Internal-team default. Allow automatic continuation help, source-worktree widening, and raw engine commands in the standard tool surface.",
        "codex_auto_resume": True,
        "codex_source_worktree_access": "auto",
        "standard_raw_command": True,
    },
    "balanced": {
        "description": "Safer default for experiments and shared branches. Disable automatic resume prompts, limit source-worktree widening to closeout flows, and hide raw engine commands from the standard tool surface.",
        "codex_auto_resume": False,
        "codex_source_worktree_access": "closeout_only",
        "standard_raw_command": False,
    },
    "strict": {
        "description": "Most restrictive mode. Automatic resume prompts stay off, source-worktree widening requires an explicit opt-in, and raw engine commands stay off the standard tool surface.",
        "codex_auto_resume": False,
        "codex_source_worktree_access": "explicit",
        "standard_raw_command": False,
    },
}


# 流程繁简，和 work_mode / policy_profile / trust_level 互相独立的第四个轴。
# work_mode: prototype 是「跳过设计和计划」，这里的 prototype-loop 是「换一种更轻的流程」，两者不是一回事。
# 各技能在 prototype-loop 下怎么做写在 shared/prototype-loop.md。
# heavy-review（重审核）：设计审查循环、计划审查循环、每阶段审查子 agent、代码审查循环里每条发现各派一个子 agent 核实，审查门守着。
# prototype-loop（原型 loop）：用户点头一份编号验收清单，每片先写检查跑出红，代码只审一轮、主 agent 自己核实，
# 收尾由没参与干活的 agent 对清单要证据；审查门关掉。
DEFAULT_WORKFLOW = "heavy-review"
WORKFLOWS = ("heavy-review", "prototype-loop")


WORK_MODE_PROFILES: dict[str, dict[str, Any]] = {
    "prototype": {
        "description": "Fast playable spike. Keep compile green, validate the idea quickly, and record keep/drop/observe.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": False,
        "test_expectation": "targeted_or_manual",
        "changes_summary_expected": True,
    },
    "feature": {
        "description": "Build a retainable feature. Prefer a concise design, a plan, compile verification, and targeted testing.",
        "design_doc_expected": True,
        "implementation_plan_expected": True,
        "review_expected": True,
        "test_expectation": "targeted",
        "changes_summary_expected": False,
    },
    "fix": {
        "description": "Bug-fix mode. Reproduce first, make the smallest safe change, and run the regression path before moving on.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": False,
        "test_expectation": "regression",
        "changes_summary_expected": False,
    },
    "hardening": {
        "description": "Stability-sensitive work. Use it for risky refactors, release prep, or anything that needs tests and review before push.",
        "design_doc_expected": False,
        "implementation_plan_expected": False,
        "review_expected": True,
        "test_expectation": "full_or_targeted",
        "changes_summary_expected": False,
    },
}


POLICY_PROFILES: dict[str, dict[str, Any]] = {
    "core": {
        "description": "Lowest-friction runtime baseline. Compile is required; tests and review stay advisory.",
        "compile_required": True,
        "test_expectation": "basic",
        "policy_check_expectation": "advisory",
        "review_expectation": "off",
        "doc_drift_expectation": "off",
        "default_test_scope": "editmode",
    },
    "feature": {
        "description": "Balanced daily-development defaults. Compile is required; targeted tests and lightweight review are expected.",
        "compile_required": True,
        "test_expectation": "targeted",
        "policy_check_expectation": "expected",
        "review_expectation": "light",
        "doc_drift_expectation": "advisory",
        "default_test_scope": "all",
    },
    "hardening": {
        "description": "Higher-confidence defaults for risky work. Expect compile, stronger tests, review, and doc/code consistency.",
        "compile_required": True,
        "test_expectation": "strong",
        "policy_check_expectation": "required",
        "review_expectation": "required",
        "doc_drift_expectation": "required",
        "default_test_scope": "all",
    },
}


DEFAULT_ENABLED_RULES: list[str] = []


DEFAULT_INSTALL = {
    "hosts": ["claude", "codex", "mcp"],
    "add_modules": [],
    "remove_modules": [],
    "sync": False,
}

VALID_INSTALL_HOSTS = set(DEFAULT_INSTALL["hosts"])


PACKS: dict[str, dict[str, Any]] = {
    "runtime-core": {
        "description": "Core runtime loop: state, go, test, changes.",
        "skills": ["go", "test", "changes"],
        "hooks": [],
    },
    "workflow-basic": {
        "description": "Basic execution, test authoring, and ship actions.",
        "skills": ["execute", "add-tests", "commit-push"],
        "hooks": [],
    },
    "workflow-planning": {
        "description": "Design and plan oriented workflow skills.",
        "skills": ["bootstrap", "design", "design-research", "plan", "post-design-review"],
        "hooks": [],
    },
    "workflow-review": {
        "description": "Review-oriented workflow skills.",
        "skills": [
            "best-practice",
            "claude-code-review",
            "claude-plan-review",
            "codex-code-review",
            "codex-plan-review",
            "self-review",
        ],
        "hooks": [],
    },
    "workflow-docs": {
        "description": "Doc consistency and project summary workflow skills.",
        "skills": ["brief", "full-brief", "timeline", "doc-tidy", "doc-drift"],
        "hooks": [],
    },
    "workflow-utility": {
        "description": "Utility skills that remain useful in most profiles.",
        "skills": ["tech-research", "explain", "grandma", "deps"],
        "hooks": [],
    },
    "hooks-auto-compile": {
        "description": "Compile engine runtime code automatically after edits.",
        "skills": [],
        "hooks": ["auto_compile"],
    },
    "hooks-compile-gate": {
        "description": "Block source edits when compile is red or project is virgin.",
        "skills": [],
        "hooks": ["compile_gate"],
    },
    "hooks-review-gate": {
        "description": "Lock edits until review findings are verified.",
        "skills": [],
        "hooks": ["review_gate"],
    },
    "hooks-skill-review": {
        "description": "Require self-review when editing qq skills/config.",
        "skills": [],
        "hooks": ["skill_review"],
    },
    "hooks-auto-pipeline": {
        "description": "Block session exit during --auto pipeline execution.",
        "skills": [],
        "hooks": ["auto_pipeline"],
    },
    "git-pre-push": {
        "description": "Run git pre-push validation according to the active profile.",
        "skills": [],
        "hooks": ["git_pre_push"],
    },
}


BUILTIN_PROFILES: dict[str, dict[str, Any]] = {
    "lightweight": {
        "description": "Smallest usable qq footprint: runtime, compile/test, explicit test authoring, go, execute, and changes with almost no ceremony.",
        "work_mode": "prototype",
        "policy_profile": "core",
        "packs": [
            "runtime-core",
            "workflow-basic",
            "workflow-utility",
            "hooks-auto-compile",
            "hooks-compile-gate",
        ],
    },
    "core": {
        "extends": "lightweight",
        "description": "Low-friction daily runtime. Keep verification light while staying on the retainable-feature path.",
        "work_mode": "feature",
        "policy_profile": "core",
    },
    "feature": {
        "extends": "core",
        "description": "Balanced feature-development defaults: plan, review, compile, explicit test authoring, and targeted validation.",
        "work_mode": "feature",
        "policy_profile": "feature",
        "add_packs": [
            "workflow-planning",
            "workflow-review",
            "hooks-review-gate",
            "hooks-auto-pipeline",
            "git-pre-push",
        ],
    },
    "hardening": {
        "extends": "feature",
        "description": "Higher-confidence profile for risky refactors, stabilization, and release prep.",
        "work_mode": "hardening",
        "policy_profile": "hardening",
        "add_packs": [
            "workflow-docs",
            "hooks-skill-review",
        ],
    },
}


ALL_KNOWN_SKILLS = sorted({skill for payload in PACKS.values() for skill in payload["skills"]})
ALL_KNOWN_HOOKS = sorted({hook for payload in PACKS.values() for hook in payload["hooks"]})


def normalize_work_mode(value: Any) -> str:
    raw = str(value or "").strip().lower()
    return WORK_MODE_ALIASES.get(raw, raw)


def normalize_policy_profile(value: Any) -> str:
    return str(value or "").strip().lower()


def normalize_trust_level(value: Any) -> str:
    return str(value or "").strip().lower()


def normalize_workflow(value: Any) -> str:
    return str(value or "").strip().lower()


def dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        ordered.append(item)
    return ordered


class ConfigError(ValueError):
    """qq.yaml / .qq/local.yaml 读不了或解析不了。

    消息里带文件名，能定位时再带行号和键名；CLI 入口把它打到 stderr 并非 0 退出。
    继承 ValueError，旧代码里 except ValueError 的地方行为不变。
    """


class _FlowParser:
    """YAML 行内写法（flow 集合）的子集：[a, b]、{k: v}，可任意嵌套。

    元素是普通标量（按 parse_scalar 的规则转成布尔 / 空值 / 数字 / 字符串）或带引号字符串；
    带引号字符串里的逗号、冒号、括号原样保留，双引号按 JSON 规则处理转义，单引号里 '' 表示一个 '。
    括号不配对、缺逗号这类写错的，以及不支持的写法（跨行的行内集合、[a: b] 这种序列里的单对映射）一律抛 ValueError，不猜。
    """

    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    def parse(self) -> Any:
        value = self._node()
        self._skip_spaces()
        if self.pos < len(self.text):
            self._fail(f"unexpected text after the closing bracket: {self.text[self.pos:]!r}")
        return value

    def _fail(self, message: str) -> NoReturn:
        raise ValueError(f"{message} at character {self.pos + 1}")

    def _peek(self) -> str:
        return self.text[self.pos] if self.pos < len(self.text) else ""

    def _describe(self) -> str:
        char = self._peek()
        return repr(char) if char else "end of value"

    def _skip_spaces(self) -> None:
        while self._peek() in (" ", "\t"):
            self.pos += 1

    def _node(self) -> Any:
        self._skip_spaces()
        char = self._peek()
        if char == "[":
            return self._sequence()
        if char == "{":
            return self._mapping()
        if char in ("'", '"'):
            return self._quoted()
        return parse_scalar(self._plain())

    def _plain(self) -> str:
        # 不带引号的标量到逗号、括号，或「冒号 + 空白/逗号/括号/结尾」为止；a:b、http://x 这种冒号不算分隔
        start = self.pos
        while self.pos < len(self.text):
            char = self.text[self.pos]
            if char in ",[]{}":
                break
            if char == ":" and (self.pos + 1 == len(self.text) or self.text[self.pos + 1] in " \t,[]{}"):
                break
            self.pos += 1
        token = self.text[start:self.pos].strip()
        if not token:
            self._fail(f"expected a value but found {self._describe()}")
        return token

    def _quoted(self) -> str:
        quote = self.text[self.pos]
        start = self.pos
        if quote == "'":
            parts: list[str] = []
            index = start + 1
            while True:
                end = self.text.find("'", index)
                if end < 0:
                    self._fail("unterminated single-quoted string")
                parts.append(self.text[index:end])
                if self.text.startswith("''", end):
                    parts.append("'")
                    index = end + 2
                    continue
                self.pos = end + 1
                return "".join(parts)
        index = start + 1
        while index < len(self.text):
            char = self.text[index]
            if char == "\\":
                index += 2
                continue
            if char == '"':
                token = self.text[start:index + 1]
                try:
                    value = json.loads(token, strict=False)
                except json.JSONDecodeError:
                    self._fail(f"invalid escape sequence in double-quoted string {token}")
                self.pos = index + 1
                return str(value)
            index += 1
        self._fail("unterminated double-quoted string")

    def _sequence(self) -> list[Any]:
        self.pos += 1
        items: list[Any] = []
        while True:
            self._skip_spaces()
            char = self._peek()
            if char == "]":
                self.pos += 1
                return items
            if char == "":
                self._fail("unterminated '[' (missing ']')")
            if char == ",":
                self._fail("expected a value but found ','")
            items.append(self._node())
            self._skip_spaces()
            char = self._peek()
            if char == ",":
                self.pos += 1
            elif char != "]":
                self._fail(f"expected ',' or ']' but found {self._describe()}")

    def _mapping(self) -> dict[str, Any]:
        self.pos += 1
        result: dict[str, Any] = {}
        while True:
            self._skip_spaces()
            char = self._peek()
            if char == "}":
                self.pos += 1
                return result
            if char == "":
                self._fail("unterminated '{' (missing '}')")
            if char in ",[]{:":
                self._fail(f"expected a key but found {self._describe()}")
            key = self._quoted() if char in ("'", '"') else self._plain()
            self._skip_spaces()
            value: Any = None
            if self._peek() == ":":
                self.pos += 1
                self._skip_spaces()
                if self._peek() not in (",", "}", ""):
                    value = self._node()
            result[key] = value
            self._skip_spaces()
            char = self._peek()
            if char == ",":
                self.pos += 1
            elif char != "}":
                self._fail(f"expected ',' or '}}' but found {self._describe()}")


def parse_scalar(value: str) -> Any:
    value = value.strip()
    if value == "":
        return ""
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if value in {"null", "Null", "none", "None", "~"}:
        return None
    if value.startswith(("'", '"')) and value.endswith(("'", '"')) and len(value) >= 2:
        return value[1:-1]
    if value.startswith("[") or value.startswith("{"):
        # 行内写法：先按 JSON 解析（保持旧行为），不是合法 JSON 再按 YAML 行内写法解析，
        # 比如 hooks: {disable: [auto_compile, compile_gate]}。旧代码在这里 JSON 失败就把整段当字符串，
        # 配置被悄悄忽略；YAML 里不带引号的值本来就不能以 [ 或 { 开头，所以两种都解析不了就抛 ValueError。
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return _FlowParser(value).parse()
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        pass
    return value


def _strip_comment(line: str) -> str:
    if "#" not in line:
        return line.rstrip()
    in_single = False
    in_double = False
    result: list[str] = []
    for char in line:
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        if char == "#" and not in_single and not in_double:
            break
        result.append(char)
    return "".join(result).rstrip()


def _preprocess_yaml(text: str) -> list[tuple[int, str, int]]:
    # 每项是（缩进, 去掉缩进和注释的内容, 原文件行号）；行号只用来报错
    lines: list[tuple[int, str, int]] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        if not raw.strip():
            continue
        stripped = _strip_comment(raw)
        if not stripped.strip():
            continue
        content = stripped.lstrip(" \t")
        if "\t" in stripped[: len(stripped) - len(content)]:
            # YAML 缩进只能用空格。旧算法只数空格，Tab 缩进的子行会被当成顶层键、整段设置悄悄丢掉
            raise ValueError(f"line {lineno}: tab character in indentation (YAML indentation must use spaces)")
        lines.append((len(stripped) - len(content), content, lineno))
    # 文件开头的文档起始标记 ---、结尾的文档结束标记 ... 都是合法 YAML，跳过；中间再出现就是多文档，不支持
    if lines and lines[0][:2] == (0, "---"):
        lines = lines[1:]
    if lines and lines[-1][:2] == (0, "..."):
        lines = lines[:-1]
    for indent, content, lineno in lines:
        if indent == 0 and content in ("---", "..."):
            raise ValueError(f"line {lineno}: only one YAML document per config file is supported (found {content!r})")
    return lines


def _key_label(path: tuple[str, ...]) -> str:
    label = ""
    for part in path:
        label += part if part.startswith("[") or not label else f".{part}"
    return label


def _under(path: tuple[str, ...]) -> str:
    return f" under key '{_key_label(path)}'" if path else ""


def _parse_value(text: str, path: tuple[str, ...], lineno: int) -> Any:
    try:
        return parse_scalar(text)
    except ValueError as exc:
        raise ConfigError(
            f"line {lineno}: key '{_key_label(path)}': cannot parse inline value {text!r}: {exc} "
            "(if it is meant as plain text, wrap the whole value in quotes)"
        ) from exc


def _split_mapping_entry(content: str, path: tuple[str, ...], lineno: int) -> tuple[str, str]:
    # 「键: 值」拆成（键, 去掉首尾空白的值）。带引号的键（"hooks": …）去掉引号，键里的冒号原样保留；
    # 旧代码按第一个冒号切、引号留在键名里，"hooks" 这个键谁也不认，整段设置被悄悄丢掉
    if content[:1] in ("'", '"'):
        parser = _FlowParser(content)
        try:
            key = parser._quoted()
        except ValueError as exc:
            raise ValueError(f"line {lineno}: invalid quoted key{_under(path)}: {exc}") from exc
        parser._skip_spaces()
        if parser._peek() == ":":
            return key, content[parser.pos + 1:].strip()
    else:
        key, sep, rest = content.partition(":")
        if sep:
            return key.strip(), rest.strip()
    raise ValueError(f"line {lineno}: invalid mapping entry{_under(path)}: {content}")


def _parse_block(
    lines: list[tuple[int, str, int]],
    index: int,
    indent: int,
    path: tuple[str, ...] = (),
) -> tuple[Any, int]:
    container: Any = None
    while index < len(lines):
        line_indent, content, lineno = lines[index]
        if line_indent < indent:
            break
        if line_indent > indent:
            raise ValueError(f"line {lineno}: unexpected indentation{_under(path)}: {content}")

        if content.startswith("- "):
            if container is None:
                container = []
            if not isinstance(container, list):
                raise ValueError(f"line {lineno}: cannot mix list and mapping entries in the same block{_under(path)}")
            item_path = (*path, f"[{len(container)}]")
            item_text = content[2:].strip()
            if item_text == "":
                item, index = _parse_block(lines, index + 1, indent + 2, item_path)
                container.append(item)
                continue
            container.append(_parse_value(item_text, item_path, lineno))
            index += 1
            continue

        if container is None:
            container = {}
        if not isinstance(container, dict):
            raise ValueError(f"line {lineno}: cannot mix mapping and list entries in the same block{_under(path)}")

        key, rest = _split_mapping_entry(content, path, lineno)
        key_path = (*path, key)
        if rest == "":
            next_index = index + 1
            next_indent = lines[next_index][0] if next_index < len(lines) else -1
            if next_indent > indent:
                # 子块的缩进以它第一行为准，2 格、4 格都行（旧代码写死上级 + 2 格，别的宽度整份解析失败）
                value, index = _parse_block(lines, next_index, next_indent, key_path)
            elif next_indent == indent and lines[next_index][1].startswith("- "):
                # 列表与上级键同缩进也是合法 YAML（PyYAML 默认就这样输出）：只收这一串 "- " 行及其子行
                end = next_index
                while end < len(lines) and (lines[end][0] > indent or (lines[end][0] == indent and lines[end][1].startswith("- "))):
                    end += 1
                value, index = _parse_block(lines[:end], next_index, indent, key_path)
            else:
                value, index = {}, index + 1
            container[key] = value
        else:
            container[key] = _parse_value(rest, key_path, lineno)
            index += 1

    if container is None:
        container = {}
    return container, index


def load_structured_file(path: Path) -> dict[str, Any]:
    # 文件不存在 = 没有这份配置；存在却读不了、解析不了一律抛 ConfigError（带文件名），不当空配置。
    if not path.is_file():
        return {}
    try:
        # utf-8-sig：Windows PowerShell 5.1 的 Out-File / Set-Content -Encoding utf8 会写 BOM；
        # 按 utf-8 读时 BOM 粘在第一个键上（键名变成 BOM 加 hooks），那一段设置被悄悄丢掉
        text = path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"{path}: cannot read config file: {exc}") from exc
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        try:
            lines = _preprocess_yaml(text)
            if not lines:
                return {}
            payload, index = _parse_block(lines, 0, lines[0][0])
            if index != len(lines):
                _, content, lineno = lines[index]
                raise ValueError(f"line {lineno}: indented less than the first line of the file: {content}")
        except ValueError as exc:
            raise ConfigError(f"{path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ConfigError(f"{path}: config root must be a mapping")
    return payload


def read_optional_structured(path: Path) -> dict[str, Any]:
    # 旧代码在这里 except Exception 一律返回 {}：写坏的配置整份被悄悄忽略，用户毫无察觉。
    # 现在只有「文件不存在」算空配置，其余 ConfigError 原样抛给调用方（qq-config.py 等入口负责报出来）。
    return load_structured_file(path)


def merge_unique(base: list[str], additions: list[str]) -> list[str]:
    return dedupe([*base, *additions])


def remove_items(items: list[str], removals: list[str]) -> list[str]:
    blocked = set(removals)
    return [item for item in items if item not in blocked]


def normalize_name_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    return []


def normalized_toggle(value: Any) -> dict[str, list[str]]:
    if not isinstance(value, dict):
        return {"enable": [], "disable": []}
    return {
        "enable": normalize_name_list(value.get("enable")),
        "disable": normalize_name_list(value.get("disable")),
    }


def normalize_install_payload(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {}

    hosts = [item for item in normalize_name_list(value.get("hosts")) if item in VALID_INSTALL_HOSTS]
    payload: dict[str, Any] = {}
    if hosts:
        payload["hosts"] = dedupe(hosts)

    add_modules = normalize_name_list(value.get("add_modules"))
    if add_modules:
        payload["add_modules"] = add_modules

    remove_modules = normalize_name_list(value.get("remove_modules"))
    if remove_modules:
        payload["remove_modules"] = remove_modules

    if isinstance(value.get("sync"), bool):
        payload["sync"] = bool(value["sync"])

    return payload


def merge_install_payload(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(DEFAULT_INSTALL)
    merged.update(base or {})
    if override.get("hosts"):
        merged["hosts"] = list(override["hosts"])
    merged["add_modules"] = merge_unique(list(merged.get("add_modules") or []), list(override.get("add_modules") or []))
    merged["remove_modules"] = merge_unique(list(merged.get("remove_modules") or []), list(override.get("remove_modules") or []))
    if "sync" in override:
        merged["sync"] = bool(override["sync"])
    return merged


def normalize_profile_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "description": str(payload.get("description") or ""),
        "extends": str(payload.get("extends") or ""),
        "work_mode": normalize_work_mode(payload.get("work_mode") or ""),
        "policy_profile": normalize_policy_profile(payload.get("policy_profile") or ""),
        "trust_level": normalize_trust_level(payload.get("trust_level") or ""),
        "workflow": normalize_workflow(payload.get("workflow") or ""),
        "packs": normalize_name_list(payload.get("packs")),
        "add_packs": normalize_name_list(payload.get("add_packs")),
        "remove_packs": normalize_name_list(payload.get("remove_packs")),
        "enabled_rules": normalize_name_list(payload.get("enabled_rules")),
        "add_rules": normalize_name_list(payload.get("add_rules")),
        "remove_rules": normalize_name_list(payload.get("remove_rules")),
        "skills": normalized_toggle(payload.get("skills")),
        "hooks": normalized_toggle(payload.get("hooks")),
    }


def merge_profile_payload(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    if override.get("description"):
        merged["description"] = override["description"]
    if override.get("work_mode"):
        merged["work_mode"] = override["work_mode"]
    if override.get("policy_profile"):
        merged["policy_profile"] = override["policy_profile"]
    if override.get("trust_level"):
        merged["trust_level"] = override["trust_level"]
    if override.get("workflow"):
        merged["workflow"] = override["workflow"]
    if override.get("packs"):
        merged["packs"] = list(override["packs"])
    merged["packs"] = remove_items(merge_unique(list(merged.get("packs") or []), list(override.get("add_packs") or [])), list(override.get("remove_packs") or []))
    if override.get("enabled_rules"):
        merged["enabled_rules"] = list(override["enabled_rules"])
    merged["enabled_rules"] = remove_items(merge_unique(list(merged.get("enabled_rules") or []), list(override.get("add_rules") or [])), list(override.get("remove_rules") or []))
    merged["skills"] = {
        "enable": merge_unique(list((merged.get("skills") or {}).get("enable") or []), list((override.get("skills") or {}).get("enable") or [])),
        "disable": merge_unique(list((merged.get("skills") or {}).get("disable") or []), list((override.get("skills") or {}).get("disable") or [])),
    }
    merged["hooks"] = {
        "enable": merge_unique(list((merged.get("hooks") or {}).get("enable") or []), list((override.get("hooks") or {}).get("enable") or [])),
        "disable": merge_unique(list((merged.get("hooks") or {}).get("disable") or []), list((override.get("hooks") or {}).get("disable") or [])),
    }
    return merged


def resolve_profile(name: str, custom_profiles: dict[str, dict[str, Any]], stack: set[str] | None = None) -> dict[str, Any]:
    stack = stack or set()
    profile_name = str(name or "").strip() or "feature"
    if profile_name in stack:
        # ConfigError 而不是普通 ValueError：入口只接 ConfigError，普通 ValueError 会吐 traceback、退 1
        raise ConfigError(f"profile inheritance cycle detected: {profile_name}")
    stack.add(profile_name)
    # 认不出的名字下面会改成按 feature 解析；出栈要用入栈时的名字，否则 remove("feature") 抛 KeyError、吐 traceback
    entered = profile_name

    if profile_name in custom_profiles:
        custom = custom_profiles[profile_name]
        if not isinstance(custom, dict):
            raise ConfigError(f"key 'profiles.{profile_name}': expected a mapping, got {custom!r}")
        payload = normalize_profile_payload(custom)
    elif profile_name in BUILTIN_PROFILES:
        payload = normalize_profile_payload(BUILTIN_PROFILES[profile_name])
    else:
        payload = normalize_profile_payload(BUILTIN_PROFILES["feature"])
        profile_name = "feature"

    base_name = payload.get("extends") or ""
    if base_name:
        base = resolve_profile(base_name, custom_profiles, stack)
    else:
        base = {
            "description": "",
            "work_mode": "feature",
            "policy_profile": "feature",
            "trust_level": "trusted",
            "packs": [],
            "enabled_rules": list(DEFAULT_ENABLED_RULES),
            "skills": {"enable": [], "disable": []},
            "hooks": {"enable": [], "disable": []},
        }

    stack.remove(entered)
    return merge_profile_payload(base, payload)


def _default_profile_from_shared(shared: dict[str, Any]) -> str:
    raw = str(shared.get("default_profile") or "").strip()
    if raw:
        return raw
    return "feature"


def _local_profile_name(local: dict[str, Any]) -> str:
    explicit = str(local.get("profile") or "").strip()
    return explicit


def _toggle_enabled(base_items: list[str], toggle: dict[str, list[str]], universe: list[str] | None = None) -> list[str]:
    enabled = merge_unique(list(base_items), list(toggle.get("enable") or []))
    enabled = remove_items(enabled, list(toggle.get("disable") or []))
    if universe is not None:
        known = set(universe)
        enabled = [item for item in enabled if item in known]
    return dedupe(enabled)


def policy_floor_packs(policy_profile: str) -> list[str]:
    packs: list[str] = []
    if policy_profile in {"feature", "hardening"}:
        packs.extend(["workflow-review", "hooks-review-gate"])
    if policy_profile == "hardening":
        packs.append("workflow-docs")
    return [pack for pack in dedupe(packs) if pack in PACKS]


def resolve_project_config(project_dir: Path) -> dict[str, Any]:
    shared_yaml_path = project_dir / "qq.yaml"
    local_yaml_path = project_dir / ".qq" / "local.yaml"

    shared = read_optional_structured(shared_yaml_path)
    shared_source = "qq_yaml" if shared else ""
    raw_version = shared.get("version")
    try:
        version = int(raw_version or 1)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{shared_yaml_path}: key 'version': expected an integer, got {raw_version!r}") from exc
    config_format = "qq_yaml" if shared_yaml_path.is_file() else "built_in_default"

    local = read_optional_structured(local_yaml_path)
    local_source = "qq_local_yaml" if local else ""

    install_preferences = merge_install_payload(
        normalize_install_payload(shared.get("install")),
        normalize_install_payload(local.get("install")),
    )

    available_engines = known_engines()
    requested_engine = normalize_engine_id(local.get("engine") or "")
    engine_source = local_source if requested_engine in available_engines else ""
    if requested_engine not in available_engines:
        requested_engine = normalize_engine_id(shared.get("engine") or "")
        engine_source = shared_source if requested_engine in available_engines else ""
    engine = resolve_project_engine(project_dir, requested_engine)
    if engine and not engine_source:
        engine_source = "detected"

    custom_profiles = shared.get("profiles") if isinstance(shared.get("profiles"), dict) else {}
    default_profile = _default_profile_from_shared(shared)
    requested_profile = _local_profile_name(local) or default_profile
    profile_source = local_source if _local_profile_name(local) else (shared_source if shared_source != "default" else "default")

    try:
        profile_defaults = resolve_profile(requested_profile, custom_profiles)
    except ConfigError as exc:
        # 内置 profile 之间不成环；自定义 profile 只能写在 qq.yaml 的 profiles 里，问题一定出在这份文件
        raise ConfigError(f"{shared_yaml_path}: {exc}") from exc
    shared_override = normalize_profile_payload(shared)
    resolved_profile = merge_profile_payload(profile_defaults, shared_override)

    work_mode = normalize_work_mode(local.get("work_mode") or "")
    work_mode_source = local_source if work_mode in WORK_MODE_PROFILES else ""
    if work_mode not in WORK_MODE_PROFILES:
        work_mode = normalize_work_mode(resolved_profile.get("work_mode") or "")
        work_mode_source = shared_source if shared_override.get("work_mode") in WORK_MODE_PROFILES else "profile"
    if work_mode not in WORK_MODE_PROFILES:
        work_mode = "feature"
        work_mode_source = "default"
    elif config_format == "built_in_default" and work_mode_source == "profile":
        work_mode_source = "default"

    policy_profile = normalize_policy_profile(local.get("policy_profile") or "")
    policy_profile_source = local_source if policy_profile in POLICY_PROFILES else ""
    if policy_profile not in POLICY_PROFILES:
        policy_profile = normalize_policy_profile(resolved_profile.get("policy_profile") or "")
        policy_profile_source = shared_source if shared_override.get("policy_profile") in POLICY_PROFILES else "profile"
    if policy_profile not in POLICY_PROFILES:
        policy_profile = "feature"
        policy_profile_source = "default"
    elif config_format == "built_in_default" and policy_profile_source == "profile":
        policy_profile_source = "default"

    trust_level = normalize_trust_level(local.get("trust_level") or "")
    trust_level_source = local_source if trust_level in TRUST_LEVELS else ""
    if trust_level not in TRUST_LEVELS:
        trust_level = normalize_trust_level(resolved_profile.get("trust_level") or "")
        trust_level_source = shared_source if shared_override.get("trust_level") in TRUST_LEVELS else "profile"
    if trust_level not in TRUST_LEVELS:
        trust_level = "trusted"
        trust_level_source = "default"
    elif config_format == "built_in_default" and trust_level_source == "profile":
        trust_level_source = "default"

    # 取值顺序同 trust_level：.qq/local.yaml > qq.yaml > profile > 默认。内置 profile 都不设它，
    # 所以来源是 profile 只说明确实有一个（自定义）profile 写了它
    workflow = normalize_workflow(local.get("workflow"))
    workflow_source = local_source
    if workflow not in WORKFLOWS:
        workflow = normalize_workflow(resolved_profile.get("workflow"))
        workflow_source = shared_source if shared_override.get("workflow") in WORKFLOWS else "profile"
    if workflow not in WORKFLOWS:
        workflow = DEFAULT_WORKFLOW
        workflow_source = "default"

    packs = list(resolved_profile.get("packs") or [])
    packs = remove_items(merge_unique(packs, normalize_name_list(local.get("add_packs"))), normalize_name_list(local.get("remove_packs")))
    packs = merge_unique(packs, policy_floor_packs(policy_profile))
    packs = [pack for pack in packs if pack in PACKS]

    engine_rules = engine_default_enabled_rules(engine) if engine else list(DEFAULT_ENABLED_RULES)
    profile_rules = list(resolved_profile.get("enabled_rules") or engine_rules)
    if not profile_rules:
        profile_rules = list(engine_rules)
    enabled_rules = remove_items(merge_unique(profile_rules, normalize_name_list(local.get("add_rules"))), normalize_name_list(local.get("remove_rules")))
    if local.get("enabled_rules"):
        enabled_rules = normalize_name_list(local.get("enabled_rules"))
    if not enabled_rules:
        enabled_rules = list(engine_rules)

    pack_skills = dedupe([skill for pack in packs for skill in PACKS[pack]["skills"]])
    pack_hooks = dedupe([hook for pack in packs for hook in PACKS[pack]["hooks"]])

    profile_skill_toggle = resolved_profile.get("skills") or {"enable": [], "disable": []}
    profile_hook_toggle = resolved_profile.get("hooks") or {"enable": [], "disable": []}
    local_skill_toggle = normalized_toggle(local.get("skills"))
    local_hook_toggle = normalized_toggle(local.get("hooks"))

    enabled_skills = _toggle_enabled(pack_skills, profile_skill_toggle, ALL_KNOWN_SKILLS)
    enabled_skills = _toggle_enabled(enabled_skills, local_skill_toggle, ALL_KNOWN_SKILLS)

    enabled_hooks = _toggle_enabled(pack_hooks, profile_hook_toggle, ALL_KNOWN_HOOKS)
    enabled_hooks = _toggle_enabled(enabled_hooks, local_hook_toggle, ALL_KNOWN_HOOKS)
    # 原型 loop 不逐条派子 agent 核实审查发现，审查门立起来就等不齐验证数、一直锁编辑，所以连带关掉；
    # hooks.enable 里明确点了名的照开（profile 链、qq.yaml、.qq/local.yaml 里写的都算）
    explicit_hooks = [*profile_hook_toggle["enable"], *local_hook_toggle["enable"]]
    if workflow == "prototype-loop" and "review_gate" not in explicit_hooks:
        enabled_hooks = remove_items(enabled_hooks, ["review_gate"])

    task_focus = local.get("task_focus")
    if task_focus is None:
        task_focus = shared.get("task_focus")

    return {
        "version": version,
        "config_format": config_format,
        "shared_config_path": str(shared_yaml_path),
        "local_config_path": str(local_yaml_path),
        "profile": requested_profile if requested_profile in BUILTIN_PROFILES or requested_profile in custom_profiles else default_profile,
        "profile_source": profile_source,
        "default_profile": default_profile,
        "profile_description": str(resolved_profile.get("description") or ""),
        "engine": engine,
        "engine_source": engine_source,
        "work_mode": work_mode,
        "work_mode_source": work_mode_source,
        "mode_profile": WORK_MODE_PROFILES[work_mode],
        "policy_profile": policy_profile,
        "policy_profile_source": policy_profile_source,
        "policy_profile_expectations": POLICY_PROFILES[policy_profile],
        "trust_level": trust_level,
        "trust_level_source": trust_level_source,
        "trust_level_expectations": TRUST_LEVELS[trust_level],
        "workflow": workflow,
        "workflow_source": workflow_source,
        "default_test_scope": engine_default_test_scope(engine, policy_profile) if engine else str(POLICY_PROFILES[policy_profile]["default_test_scope"]),
        "packs": packs,
        "pack_details": {name: PACKS[name] for name in packs},
        "available_profiles": sorted({*BUILTIN_PROFILES.keys(), *custom_profiles.keys()}),
        "available_packs": sorted(PACKS.keys()),
        "available_engines": available_engines,
        "enabled_skills": enabled_skills,
        "enabled_hooks": enabled_hooks,
        "enabled_rules": enabled_rules,
        "task_focus": task_focus,
        "install_preferences": install_preferences,
        "available_install_hosts": sorted(VALID_INSTALL_HOSTS),
        "shared_config_exists": shared_yaml_path.is_file(),
        "local_config_exists": local_yaml_path.is_file(),
    }


def emit(payload: Any, pretty: bool) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2 if pretty else None, sort_keys=pretty))


def emit_field(payload: dict[str, Any], field: str) -> None:
    value = payload.get(field, "")
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value, ensure_ascii=False, sort_keys=True))
    else:
        print(value)


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve qq profile/config state")
    subparsers = parser.add_subparsers(dest="command", required=False)

    def add_project_arg(target: argparse.ArgumentParser) -> None:
        target.add_argument("--project", default=".", help="Project root (defaults to cwd)")
        target.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    resolve_parser = subparsers.add_parser("resolve", help="Resolve the effective qq config")
    add_project_arg(resolve_parser)

    field_parser = subparsers.add_parser("field", help="Print a single resolved field")
    field_parser.add_argument("field", help="Field name to print")
    field_parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")

    hook_parser = subparsers.add_parser("hook-enabled", help="Print whether a hook is enabled")
    hook_parser.add_argument("hook", help="Hook id")
    hook_parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")

    skill_parser = subparsers.add_parser("skill-enabled", help="Print whether a skill is enabled")
    skill_parser.add_argument("skill", help="Skill id")
    skill_parser.add_argument("--project", default=".", help="Project root (defaults to cwd)")

    args = parser.parse_args()
    command = args.command or "resolve"
    project_dir = Path(getattr(args, "project", ".")).resolve()
    try:
        payload = resolve_project_config(project_dir)
    except ConfigError as exc:
        # 所有子命令都走这里：stdout 不输出任何结果，免得调用方把半截结果当真
        print(f"qq-config: error: {exc}", file=sys.stderr)
        return 2

    if command == "field":
        emit_field(payload, args.field)
        return 0
    if command == "hook-enabled":
        print("true" if args.hook in payload["enabled_hooks"] else "false")
        return 0
    if command == "skill-enabled":
        print("true" if args.skill in payload["enabled_skills"] else "false")
        return 0

    emit(payload, getattr(args, "pretty", False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
