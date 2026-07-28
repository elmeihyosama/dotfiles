#!/bin/sh
# sessionize.sh — fuzzy-pick a project and open/attach/switch a zellij session
# named for it. Sources: `fd` over $SESSIONIZE_ROOTS (git repos / immediate
# subdirs) merged with zoxide frecency, deduped. Standalone-testable:
#   sessionize.sh            interactive (fzf) → create/attach/switch
#   sessionize.sh --list     print deduped candidate paths, no fzf
#   sessionize.sh --name P   print the sanitized session name for path P
#   sessionize.sh --table    print collision-aware "NAME<TAB>PATH" for all candidates
set -eu

: "${SESSIONIZE_ROOTS:=$HOME/workspace $HOME/workspaces $HOME/projects $HOME/dotfiles}"

# Fold a string into a zellij-legal name fragment: zellij rejects '.' '/' and
# whitespace, so map junk to '-', strip leading dots, trim dashes.
_sanitize() {
	printf '%s' "$1" | sed -e 's/^\.*//' -e 's/[^A-Za-z0-9_-]/-/g' -e 's/--*/-/g' -e 's/^-*//' -e 's/-*$//'
}

# Sanitize a path's basename into a zellij session name. Resolve to a real
# absolute path first so '.'/'..' become the actual directory name; guarantee a
# non-empty, flag-safe result by falling back to 'session'.
session_name() {
	path=$(cd "$1" 2>/dev/null && pwd || printf '%s' "$1")
	path=${path%/}
	name=$(_sanitize "${path##*/}")
	[ -n "$name" ] || name=session
	printf '%s\n' "$name"
}

# Sanitized basename of a path's PARENT dir — used to disambiguate name clashes.
parent_component() {
	p=$(cd "$1" 2>/dev/null && pwd || printf '%s' "$1")
	p=${p%/}
	p=${p%/*}
	_sanitize "${p##*/}"
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

# Emit "NAME<TAB>PATH" for every candidate. When two candidates' base names
# collide (e.g. ~/a/docs and ~/b/docs both → "docs"), prefix the colliding ones
# with their parent-dir component ("a-docs" / "b-docs") so a picked project
# always maps to its own session instead of hijacking another dir's session.
candidate_table() {
	list_candidates | while IFS= read -r p; do
		[ -n "$p" ] || continue
		printf '%s\t%s\t%s\n' "$(session_name "$p")" "$(parent_component "$p")" "$p"
	done | awk -F'\t' '
		{ nm[NR] = $1; par[NR] = $2; pth[NR] = $3; cnt[$1]++ }
		END {
			for (i = 1; i <= NR; i++) {
				name = nm[i]
				if (cnt[nm[i]] > 1 && par[i] != "") name = par[i] "-" nm[i]
				printf "%s\t%s\n", name, pth[i]
			}
		}
	'
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
--table)
	candidate_table
	exit 0
	;;
esac

# Interactive default path (no args): fuzzy-pick a project (showing the
# collision-aware name), then create/attach/switch a zellij session for it.
choose() {
	candidate_table | fzf --prompt='project ❯ ' --height=40% --reverse \
		--delimiter='\t' --with-nth=1 \
		--preview 'eza --icons --color=always {2} 2>/dev/null || ls {2}' 2>/dev/null
}

main() {
	command -v fzf >/dev/null 2>&1 || {
		echo "sessionize: fzf not found" >&2
		exit 1
	}
	command -v zellij >/dev/null 2>&1 || {
		echo "sessionize: zellij not found" >&2
		exit 1
	}

	selection=$(choose) || exit 0
	[ -n "$selection" ] || exit 0
	name=$(printf '%s' "$selection" | cut -f1)
	path=$(printf '%s' "$selection" | cut -f2-)
	[ -n "$path" ] || exit 0

	if [ -z "${ZELLIJ:-}" ]; then
		# Not inside zellij: attach-or-create. New session inherits cwd; glow is
		# the default_layout, so no explicit --layout needed.
		cd "$path" || {
			echo "sessionize: cannot cd to '$path' (stale entry?)" >&2
			exit 1
		}
		exec zellij attach -c "$name"
	else
		# Inside zellij: switch-session's create-on-missing behaviour is
		# condition-dependent (observed both no-op and auto-create); we
		# create-first (idempotent) so this is correct either way. The cd seeds
		# the created (attach -b) session's initial cwd; --cwd re-affirms it.
		cd "$path" || {
			echo "sessionize: cannot cd to '$path' (stale entry?)" >&2
			exit 1
		}
		if ! zellij list-sessions -s 2>/dev/null | grep -qx "$name"; then
			zellij attach -b "$name" >/dev/null 2>&1 || true
		fi
		exec zellij action switch-session "$name" --cwd "$path" --layout glow
	fi
}

main
