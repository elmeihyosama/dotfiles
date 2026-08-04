# LS_COLORS via vivid (a binary fork) — cached to a file; regenerate only when
# the rendered theme changes (rides `chezmoi apply`, bumping mtime) or vivid is
# upgraded. Colors file types in eza/fd listings and fzf-tab completion.
if command -v vivid >/dev/null 2>&1; then
  _vivid_cache="${XDG_CACHE_HOME:-$HOME/.cache}/vivid/ls_colors"
  _vivid_theme="${XDG_CONFIG_HOME:-$HOME/.config}/vivid/themes/base16-active.yml"
  if [[ ! -s "$_vivid_cache" || "$_vivid_theme" -nt "$_vivid_cache" \
        || ${commands[vivid]:A} -nt "$_vivid_cache" ]]; then
    mkdir -p "${_vivid_cache:h}"
    vivid generate base16-active >| "$_vivid_cache" 2>/dev/null \
      || rm -f "$_vivid_cache"
  fi
  [[ -s "$_vivid_cache" ]] && export LS_COLORS="$(<"$_vivid_cache")"
  unset _vivid_cache _vivid_theme
fi
