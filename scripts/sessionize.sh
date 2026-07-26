#!/bin/sh
# sessionize.sh — fuzzy-pick a project and open/attach/switch a zellij session
# named for it. Sources: `fd` over $SESSIONIZE_ROOTS (git repos / immediate
# subdirs) merged with zoxide frecency, deduped. Standalone-testable:
#   sessionize.sh            interactive (fzf) → create/attach/switch
#   sessionize.sh --list     print deduped candidate paths, no fzf
#   sessionize.sh --name P   print the sanitized session name for path P
set -eu

: "${SESSIONIZE_ROOTS:=$HOME/workspace $HOME/workspaces $HOME/projects $HOME/dotfiles}"

# Sanitize a path's basename into a zellij-legal session name: zellij rejects
# '.' '/' and whitespace in names, so fold them to '-' and strip leading dots.
# Resolve to a real absolute path first so '.'/'..' become the actual directory
# name; fold junk to '-', trim leading/trailing dashes, and guarantee a
# non-empty, flag-safe result by falling back to 'session'.
session_name() {
	path=$(cd "$1" 2>/dev/null && pwd || printf '%s' "$1")
	path=${path%/}
	base=${path##*/}
	name=$(printf '%s' "$base" | sed -e 's/^\.*//' -e 's/[^A-Za-z0-9_-]/-/g' -e 's/--*/-/g' -e 's/^-*//' -e 's/-*$//')
	[ -n "$name" ] || name=session
	printf '%s\n' "$name"
}

list_candidates() {
	# fd (fallback find) for directories at depth 1-2 under each existing root,
	# preferring those that are git repos; merge with zoxide frecency; dedup.
	{
		for root in $SESSIONIZE_ROOTS; do
			[ -d "$root" ] || continue
			if command -v fd >/dev/null 2>&1; then
				fd --absolute-path --type d --max-depth 2 --hidden --glob '.git' "$root" 2>/dev/null |
					sed 's#/\.git/*$##'
				fd --absolute-path --type d --max-depth 1 . "$root" 2>/dev/null
			else
				find "$root" -maxdepth 2 -type d -name .git 2>/dev/null | sed 's#/\.git$##'
				find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true
			fi
		done
		command -v zoxide >/dev/null 2>&1 && zoxide query -l 2>/dev/null
	} | sed 's#/$##' | awk 'NF && !seen[$0]++'
}

case "${1:-}" in
--list)
	list_candidates
	exit 0
	;;
--name)
	[ -n "${2:-}" ] || {
		echo "sessionize: --name needs a path" >&2
		exit 2
	}
	session_name "$2"
	exit 0
	;;
esac

# Interactive default path (no args): fuzzy-pick a project, then create/attach/
# switch a zellij session named for it.
choose() {
	list_candidates | fzf --prompt='project ❯ ' --height=40% --reverse \
		--preview 'eza --icons --color=always {} 2>/dev/null || ls {}' 2>/dev/null
}

main() {
	path=$(choose) || exit 0
	[ -n "$path" ] || exit 0
	name=$(session_name "$path")

	if [ -z "${ZELLIJ:-}" ]; then
		# Not inside zellij: attach-or-create. New session inherits cwd; glow is
		# the default_layout, so no explicit --layout needed.
		cd "$path" || exit 1
		exec zellij attach -c "$name"
	else
		# Inside zellij: switch-session's create-on-missing behaviour is
		# condition-dependent (observed both no-op and auto-create); we
		# create-first (idempotent) so this is correct either way.
		cd "$path" || exit 1
		if ! zellij list-sessions -s 2>/dev/null | grep -qx "$name"; then
			zellij attach -b "$name" >/dev/null 2>&1 || true
		fi
		exec zellij action switch-session "$name" --cwd "$path" --layout glow
	fi
}

main
