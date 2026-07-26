# theme — switch the active base16 theme (per-machine; no git diff).
#   theme            fzf-pick from available themes
#   theme <slug>     set directly
_theme_set_config() {
  # $1 = config path, $2 = slug. Set theme="slug" inside the [data] table,
  # scoped to [data] only. Replaces an existing or commented theme key; if
  # [data] exists without one, inserts it there; if [data] is absent, appends
  # a new [data] table. Writes back in place to preserve mode/inode/symlink.
  local cfg=$1 slug=$2 tmp
  tmp=$(mktemp) || return 1
  awk -v slug="$slug" '
    /^[[:space:]]*\[/ {
      if (indata && !done) { print "    theme = \"" slug "\""; done=1 }
      indata = ($0 ~ /^[[:space:]]*\[data\][[:space:]]*$/)
      print; next
    }
    indata && /^[[:space:]]*#?[[:space:]]*theme[[:space:]]*=/ && !done {
      print "    theme = \"" slug "\""; done=1; next
    }
    { print }
    END {
      if (indata && !done) { print "    theme = \"" slug "\""; done=1 }
      if (!done) { print "[data]"; print "    theme = \"" slug "\"" }
    }
  ' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$cfg"
  rm -f "$tmp"
}

theme() {
  emulate -L zsh
  local src cfg slug
  src=$(chezmoi source-path 2>/dev/null) || { echo "theme: chezmoi not found" >&2; return 1; }
  cfg=${CHEZMOI_CONFIG:-$HOME/.config/chezmoi/chezmoi.toml}
  [[ -f $cfg ]] || { echo "theme: missing $cfg" >&2; return 1; }
  local -a themes
  themes=(${src}/.chezmoidata/themes/*.toml(:t:r))
  if (( $# )); then
    slug=$1
  elif command -v fzf >/dev/null 2>&1; then
    slug=$(print -l -- $themes | fzf --prompt='theme ❯ ' --height 40% --reverse \
      --preview="${src:h}/scripts/theme-preview.sh ${src}/.chezmoidata/themes/{}.toml") || return 0
  else
    echo "usage: theme <slug>" >&2; print -l -- $themes; return 1
  fi
  [[ -z $slug ]] && return 0
  if [[ ! $slug =~ '^[A-Za-z0-9._-]+$' ]]; then
    echo "theme: invalid slug '${slug}'" >&2; return 1
  fi
  if [[ ! -f ${src}/.chezmoidata/themes/${slug}.toml ]]; then
    echo "theme: unknown theme '${slug}'" >&2; return 1
  fi
  _theme_set_config "$cfg" "$slug" || return 1
  chezmoi apply || return 1
  # cmux reads ~/.config/ghostty/config directly; repaint running sessions live.
  command -v cmux >/dev/null 2>&1 && cmux reload-config >/dev/null 2>&1
  echo "theme → ${slug}.  cmux repaints live; new shells, ghostty windows, zellij & nvim need a restart to fully apply."
  exec zsh
}
