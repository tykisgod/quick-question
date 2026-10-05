---
name: qq-local-plugin-update
description: How to install a freshly released qq version on this Windows machine (active-runtime + ~/.claude + account profiles)
metadata:
  node_type: memory
  type: reference
  originSessionId: 079072d2-e280-4cd9-9a49-115844598b72
  modified: 2026-10-05T00:13:33.517Z
---

After `scripts/qq-release.sh` publishes a version, the running sessions only pick it up from the active-runtime profile, and only after a restart.

1. Native CLI, not the `claude` wrapper: `C:/Users/ASUS/AppData/Roaming/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe`, with `CLAUDE_CONFIG_DIR=C:/Users/ASUS/Documents/Codex/local-services/fixed-egress/private/account-profiles/active-runtime/claude`:
   - `plugin marketplace update quick-question-marketplace`
   - `plugin update qq@quick-question-marketplace --scope user -y`
   - from `E:/dpp_new/new_2/project_pirate_demo`: same with `--scope project`
   - check `active-runtime/claude/plugins/installed_plugins.json`
2. Mirror to `~/.claude/plugins` and `account-profiles/data/account-*/claude/plugins` (precedent set at 1.19.3 / 1.19.4):
   - `git pull --ff-only` in `~/.claude/plugins/marketplaces/quick-question-marketplace`
   - copy `active-runtime/.../cache/quick-question-marketplace/qq/<ver>` to `~/.claude/plugins/cache/quick-question-marketplace/qq/<ver>`
   - in every `installed_plugins.json` there, update only the **user**-scope qq entry (installPath → the `~/.claude` cache dir, version, gitCommitSha, lastUpdated); project/local entries were left as they were
   - bump `lastUpdated` of `quick-question-marketplace` in `known_marketplaces.json`
   - files are indent-2 JSON without a trailing newline; account-0004/0006 have no plugins dir
3. Tell TYK the new version only takes effect after the session is restarted.
