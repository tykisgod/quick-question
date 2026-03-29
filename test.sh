#!/usr/bin/env bash
# test.sh — Self-tests for quick-question repo
# Run: ./test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { ((PASS++)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗${NC} $1"; }

# ── 1. ShellCheck ──
echo -e "${CYAN}[1/7] ShellCheck${NC}"
if command -v shellcheck &>/dev/null; then
  SHELL_FILES=$(find "$SCRIPT_DIR/scripts" -name "*.sh" -not -type l)
  SHELL_FILES="$SHELL_FILES $SCRIPT_DIR/install.sh $SCRIPT_DIR/test.sh"
  SC_FAIL=0
  for f in $SHELL_FILES; do
    if shellcheck -S error "$f" >/dev/null 2>&1; then
      pass "$(basename "$f")"
    else
      fail "$(basename "$f")"
      shellcheck -S error "$f" 2>&1 | head -20
      SC_FAIL=1
    fi
  done
  [ "$SC_FAIL" -eq 0 ] || echo ""
else
  echo -e "  ${CYAN}shellcheck not installed — skipping (brew install shellcheck)${NC}"
fi

# ── 2. JSON validity ──
echo -e "${CYAN}[2/7] JSON validity${NC}"
for json_file in hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  if [ -f "$SCRIPT_DIR/$json_file" ]; then
    if python3 -m json.tool "$SCRIPT_DIR/$json_file" >/dev/null 2>&1; then
      pass "$json_file"
    else
      fail "$json_file — invalid JSON"
    fi
  else
    fail "$json_file — file not found"
  fi
done

# ── 3. Structural checks ──
echo -e "${CYAN}[3/7] Structural checks${NC}"

# Every skill directory has a SKILL.md
SKILL_DIRS=$(find "$SCRIPT_DIR/skills" -mindepth 1 -maxdepth 1 -type d)
for dir in $SKILL_DIRS; do
  name=$(basename "$dir")
  if [ -f "$dir/SKILL.md" ]; then
    pass "skills/$name/SKILL.md exists"
  else
    fail "skills/$name/SKILL.md missing"
  fi
done

# Hook scripts referenced in hooks.json actually exist
HOOK_SCRIPTS=$(grep -oE 'scripts/[a-z/._-]+\.sh' "$SCRIPT_DIR/hooks/hooks.json" || true)
for script in $HOOK_SCRIPTS; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    pass "hooks.json → $script exists"
  else
    fail "hooks.json → $script NOT FOUND"
  fi
done

# install.sh copies hooks subdirectory
if grep -q 'scripts/hooks/' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh copies scripts/hooks/"
else
  fail "install.sh missing scripts/hooks/ copy"
fi

# Symlinks in tykit Scripts~/ point to valid targets
TYKIT_SCRIPTS="$SCRIPT_DIR/packages/com.tyk.tykit/Scripts~"
if [ -d "$TYKIT_SCRIPTS" ]; then
  for link in "$TYKIT_SCRIPTS"/*.sh; do
    if [ -L "$link" ]; then
      if [ -e "$link" ]; then
        pass "symlink $(basename "$link") → valid"
      else
        fail "symlink $(basename "$link") → BROKEN"
      fi
    fi
  done
fi

# ── 4. README consistency ──
echo -e "${CYAN}[4/7] README consistency${NC}"

ACTUAL_SKILL_COUNT=$(find "$SCRIPT_DIR/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if grep -qE "\*\*${ACTUAL_SKILL_COUNT} Slash Commands\*\*" "$SCRIPT_DIR/README.md"; then
  pass "README skill count ($ACTUAL_SKILL_COUNT) matches actual"
else
  fail "README skill count does not match actual ($ACTUAL_SKILL_COUNT skills)"
fi

for dir in $SKILL_DIRS; do
  name=$(basename "$dir")
  if grep -q "/qq:${name}" "$SCRIPT_DIR/README.md"; then
    pass "skill $name in README"
  else
    fail "skill $name NOT in README"
  fi
done

# ── 5. SKILL.md frontmatter ──
echo -e "${CYAN}[5/7] SKILL.md frontmatter${NC}"

for dir in $SKILL_DIRS; do
  name=$(basename "$dir")
  if head -1 "$dir/SKILL.md" | grep -q '^---'; then
    if grep -q '^description:' "$dir/SKILL.md"; then
      pass "skills/$name has frontmatter + description"
    else
      fail "skills/$name missing description in frontmatter"
    fi
  else
    fail "skills/$name missing frontmatter (---)"
  fi
done

# ── 6. Script permissions ──
echo -e "${CYAN}[6/7] Script permissions${NC}"

for f in "$SCRIPT_DIR"/scripts/*.sh "$SCRIPT_DIR"/scripts/hooks/*.sh "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/test.sh"; do
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    if [ -x "$f" ]; then
      pass "$(basename "$f") is executable"
    else
      fail "$(basename "$f") NOT executable"
    fi
  fi
done

# ── 7. install.sh validation ──
echo -e "${CYAN}[7/7] install.sh validation${NC}"

# Check no old skill names remain in output
if grep -qE '/qq-ut|/qq-cp|/qq-arch-review' "$SCRIPT_DIR/install.sh"; then
  fail "install.sh still has old skill names"
else
  pass "install.sh uses current skill names"
fi

# Check platform guard exists
if grep -q 'uname.*Darwin' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh has macOS platform check"
else
  fail "install.sh missing platform check"
fi

# ── Summary ──
echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All $TOTAL checks passed${NC}"
else
  echo -e "${RED}$FAIL/$TOTAL checks failed${NC}"
  exit 1
fi
