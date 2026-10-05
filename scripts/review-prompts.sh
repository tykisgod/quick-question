#!/usr/bin/env bash
# review-prompts.sh — Prompt sections shared by the four review scripts.
# Source this file; it defines functions only. Each function prints one prompt section to stdout.
#
#   qq_review_provenance_section        -> plan-review.sh / claude-plan-review.sh
#   qq_review_test_quality_section      -> code-review.sh / claude-review.sh
#   qq_review_spec_section <path>...    -> code-review.sh / claude-review.sh, only with --spec
#
# 这几段永远附在审查提示后面，不放进可被 --prompt / 第二个参数整段替换的默认标准里：
# 第二轮起各技能会传自定义提示（「按第一轮同样的标准…」），默认标准里的条目会被一并换掉。
#
# 出处检查只管三类（保护、额外加的限制、砍范围），而且只认用户本人的话：
# 「作者自拍」、agent 自己记的决策日志、没引用户原话的旧文档都不算——否则标一句就能过审，等于没管。
# 其余普通规则、数值、技术选择一律不查，免得文档到处是出处标签。三类的定义见 shared/user-decisions.md。

qq_review_provenance_section() {
  # 三类的定义与 shared/user-decisions.md 一致（test.sh 核对：保护、额外限制逐字相同，砍范围以它为前缀，spec 段带上同一句豁免）：审查进程未必读得到插件目录，所以这里内联一份
  cat <<'EOF'
## Provenance Check (always apply, in addition to the criteria above)

Check only three kinds of items. They are the user's call, never the author's:
- Protection: something exempt from a rule everything else follows (cannot be hit, cannot be destroyed, keeps a minimum, skipped by targeting).
- Added restriction: a rule whose purpose is to stop, or make costlier, a player choice the other rules allow (anti-exploit rules, "to prevent the player from X", e.g. refusing a one-sided trade). Not this kind: how a new thing works (where it can be placed, what it needs, what it connects to), or a gate without which the game crashes or gets stuck. Blocking a choice because the numbers come out wrong is not a gate: fix the numbers.
- Scope cut: delivering less than the user's request: dropping part of it, deferring it out of the plan, or replacing it with a smaller or different version. Putting work into a later milestone of the same plan is not a cut. Compare the document with the user's request quoted at its top; if none is quoted, say so in one line outside the Provenance finding (a missing quote alone is not a finding).

Only the user's words back these: an inline (user: "...") quote, or a citation that quotes them. Open every citation and check that it actually covers this item. Not a source: a decision stretched to a new case, a citation you cannot find, "the author's call", a decision-journal entry without the user's words, an earlier doc that does not quote the user, "the user approved this section", a blanket note such as "unmarked lines are the user's". If the document says the user wrote it, its own text is their words. In an implementation plan, an item taken from the design doc it names is backed only if the design doc backs it.

Report all unbacked items as ONE [Critical] finding that lists them, starting with "Provenance:". Skip items on the document's "Needs the user's decision" list. Do not report ordinary rules, numbers, or technical choices.
EOF
}

qq_review_test_quality_section() {
  cat <<'EOF'
## Test Quality (only when the diff adds or changes tests)

For each new or changed test:
1. Would it fail if the behavior it protects broke? Flag tests that still pass after a plausible bug, e.g. they only assert "no exception", or assert a value the test assigned itself.
2. Where do the expected values come from? An expectation computed with the same formula, code path, or config as the code under test is a tautology, not a check. Hand-calculated literals, worked examples from the design, or real-world data are independent.
3. Where it matters, does it check both directions: the thing happens when it should, and does not when it should not?
4. For values designers will keep tuning, assert relations (greater than, monotonic, conserved) instead of literals; keep the independent literals of point 2 for rules that should not change.

Report problems as [Critical] / [Moderate] / [Suggestion].
EOF
}

qq_review_spec_section() {
  printf '%s\n\n' "## Spec Conformance (report separately from the severity findings)"
  printf '%s\n' "Specs for this change; read them from disk:"
  local p
  for p in "$@"; do
    printf -- '- %s\n' "$p"
  done
  cat <<'EOF'

Compare what the code now does against these specs. If a spec has an Acceptance Checklist, go through it item by item; also check every concrete thing a spec names for change (classes, fields, comments, "must" and "also fix" lines). Report in a section of its own titled "Spec Conformance", with these lists:
1. Missing or partial: the spec requires it, and the code does not do it, or does only part of it.
2. Wrong: implemented, but behaves differently from what the spec says. If the code documents a deliberate deviation with a reason (a comment or commit), say so in the item.
3. Unrequested: protections or added restrictions in the diff that no spec line or user quote asks for (a protection is exempt from a rule everything else follows; an added restriction exists to stop or tax a player choice the other rules allow). Not this kind: how a new thing works (where it can be placed, what it needs, what it connects to), or a gate without which the game crashes or gets stuck. Leave out ordinary rules, numbers, and details the spec leaves open.
4. Needs runtime check: things only the running game can confirm, each with how to check it.

How to judge:
- Not due yet is not missing: when the plan splits the work into Milestones, items in milestones the code has not reached (judge from the plan's ticked steps or progress notes) and items under "Not in this plan" go in one line ("N items not due yet"). When you cannot tell, list the item as Missing.
- Before listing something as Missing, check whether it already exists elsewhere in the codebase; the diff may cover only part of the feature. Where a spec says to keep existing behavior, follow that code path one step before calling it missing.
- Every finding above that breaks a spec line is listed here too.
- For every item in lists 1 and 2, cite the spec file and heading, and quote the line.
- Tag every item [Spec] instead of a severity.
EOF
}
