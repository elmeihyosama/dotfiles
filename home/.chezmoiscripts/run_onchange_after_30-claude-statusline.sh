#!/usr/bin/env bash
# Wire the Claude Code statusline into ~/.claude/settings.json. chezmoi owns the
# statusline script and this hook, but settings.json also holds machine-local keys
# (permissions, plugins), so we jq-merge only the statusLine rather than overwrite it.
# run_onchange: re-runs only when this script changes; the merge is idempotent.
set -euo pipefail
settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$settings" ] || printf '{}\n' >"$settings"
tmp="$(mktemp)"
jq --arg cmd "$HOME/.claude/statusline.sh" \
	'.statusLine = {type: "command", command: $cmd}' "$settings" >"$tmp"
mv "$tmp" "$settings"
