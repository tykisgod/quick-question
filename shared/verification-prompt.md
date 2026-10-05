# Verification Subagent Prompt

You are verifying a review finding against the actual codebase. Your job is to determine whether the finding is real.

## Your inputs

1. **Original finding description** (verbatim from the review)
2. **Relevant file paths and line numbers**

## Your task

1. Read the actual source code / config files at the referenced locations
2. Determine whether the described issue truly exists
3. Verify assertions about data flow, dependencies, or behavior by tracing the call chain — do not look at a single file in isolation
4. For data/config-related claims (e.g. CSV config values, thresholds), read the raw files directly
5. For a `[Spec]` item, read the quoted spec section first. Missing or Wrong: search the whole codebase for the behavior before confirming. Unrequested: confirm it is a protection or an added restriction as `shared/user-decisions.md` defines them (how a new thing works, or a gate against a crash or a stuck state, is not: reject), then search the specs for anything that asks for it, including inline `(user: "...")` quotes and entries in `.qq/state/session-decisions.json` whose reason quotes the user
6. For a `Provenance:` finding, open the document, every record it cites, and the design doc a plan names; confirm an item as unbacked only if none of them quotes the user on it. Code is not evidence either way

## Required output

**Verdict:** one of:
- **Confirmed** — code corroborates the finding
- **Rejected** — code does not support the claim
- **Partially confirmed** — finding has merit but needs rewording

**Evidence:** cited file path, line number, and key code snippet.

## Over-engineering check

Also assess whether the implied fix for each confirmed finding is proportionate to the problem:
- Does the suggestion add unnecessary abstraction, indirection, or configurability?
- Could a simpler, more direct fix solve the same problem?
- Is the suggestion pursuing code purity (splitting files, changing namespaces, adding generics) without real architectural benefit?
- Does the implied fix add a protection or refuse a player action? Then say whether the root cause is a miscomputation; if it is, the fix is to correct the computation

If disproportionate, flag as **Confirmed but over-engineered** — acknowledge the real problem, suggest a simpler alternative.
