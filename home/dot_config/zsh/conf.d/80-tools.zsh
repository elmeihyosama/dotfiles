# Zoxide (guarded). `z <dir>` to jump by frecency; `zz` for interactive (see aliases).
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh --cmd z)"
fi

# navi cheatsheets are available as the `navi` command (no key widget, by preference).

# dotfiles — front end for this repo's tooling (list, doctor, ...). The script
# lives in the repo; resolve it like `theme` does.
dotfiles() {
  local src
  src=$(chezmoi source-path 2>/dev/null) || { echo "dotfiles: chezmoi not found" >&2; return 1; }
  sh "${src:h}/scripts/dotfiles.sh" "$@"
}

# doctor — read-only health check of this machine's provisioning (tools, font,
# chezmoi drift, theme, login shell). Same as `dotfiles doctor`.
doctor() { dotfiles doctor "$@" }

# Tab completion: subcommands first; add/remove then complete tool and group
# names from the catalog (read with the pinned yq on PATH via the mise shims).
_dotfiles() {
  local src
  local -a subs names
  if (( CURRENT == 2 )); then
    subs=('list:tools and their install state' 'doctor:read-only health check' 'help:show usage')
    _describe 'subcommand' subs
    return
  fi
  case $words[2] in
    add|remove)
      src=$(chezmoi source-path 2>/dev/null) || return
      (( $+commands[yq] )) || return
      names=(${(f)"$(yq '(.tools | keys | .[]), .tool_groups[]' "$src/.chezmoidata/tools.yaml" 2>/dev/null)"})
      _describe 'tool or group' names
      ;;
    list) _describe 'option' '(--json:machine-readable output)' ;;
  esac
}
compdef _dotfiles dotfiles
