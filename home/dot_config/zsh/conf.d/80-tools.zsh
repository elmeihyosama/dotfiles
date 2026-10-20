# Zoxide (guarded): `z <dir>` jumps by frecency; `zz` is interactive.
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh --cmd z)"
fi


# dotfiles: this repo's CLI; resolve the script like `theme` does.
dotfiles() {
  local src
  src=$(chezmoi source-path 2>/dev/null) || { echo "dotfiles: chezmoi not found" >&2; return 1; }
  sh "${src:h}/scripts/dotfiles.sh" "$@"
}

# doctor: same as `dotfiles doctor`.
doctor() { dotfiles doctor "$@" }

# Completion: subcommands, then tool/group names for add/remove.
_dotfiles() {
  local src
  local -a subs names
  if (( CURRENT == 2 )); then
    subs=('list:tools and their install state' 'add:select tools or groups' 'remove:deselect tools or groups' 'update:pull, apply and verify (--check to preview)' 'doctor:read-only health check' 'tui:full-screen tools, health, update and look' 'look:theme and glass as JSON (--json)' 'theme:switch theme (headless)' 'glass:set the glass level (headless)' 'help:show usage')
    _describe 'subcommand' subs
    return
  fi
  case $words[2] in
    add|remove)
      src=$(chezmoi source-path 2>/dev/null) || return
      (( $+commands[yq] )) || return
      names=(${(f)"$(yq '(.tools | keys | .[]), .tool_groups[]' "$src/.chezmoidata/tools.yaml" 2>/dev/null)"})
      _describe 'tool or group' names
      compadd -- --no-apply
      ;;
    list) compadd -- --json ;;
    update) compadd -- --check ;;
    look) compadd -- --json ;;
    # 45-theme.zsh's completers
    theme) (( CURRENT == 3 )) && _theme_slugs ;;
    glass) (( CURRENT == 3 )) && _glass_levels ;;
  esac
}
compdef _dotfiles dotfiles
