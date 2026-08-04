# _chezmoi_set_data KEY VALUE CFG — set `KEY = "VALUE"` inside the [data] table
# of the chezmoi config, scoped to [data] only. Replaces an existing or
# commented KEY; if [data] exists without it, inserts it there; if [data] is
# absent, appends a new [data] table. Writes back in place to preserve
# mode/inode/symlink. Used by `theme` and `wallpaper`. KEY must be a literal
# name (no regex metacharacters) since it is interpolated into an awk regex.
_chezmoi_set_data() {
  local key=$1 val=$2 cfg=$3 tmp
  # KEY is interpolated into an awk regex and VAL into a "..."-quoted TOML value;
  # reject a value containing a double-quote (would emit malformed TOML). Both
  # current callers pass safe strings, but this guards a future third caller.
  [[ $val == *'"'* ]] && { print -u2 "_chezmoi_set_data: value may not contain a double-quote"; return 1; }
  tmp=$(mktemp) || return 1
  awk -v key="$key" -v val="$val" '
    /^[[:space:]]*\[/ {
      if (indata && !done) { print "    " key " = \"" val "\""; done=1 }
      indata = ($0 ~ /^[[:space:]]*\[data\][[:space:]]*$/)
      print; next
    }
    indata && $0 ~ ("^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") && !done {
      print "    " key " = \"" val "\""; done=1; next
    }
    { print }
    END {
      if (indata && !done) { print "    " key " = \"" val "\""; done=1 }
      if (!done) { print "[data]"; print "    " key " = \"" val "\"" }
    }
  ' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$cfg"
  rm -f "$tmp"
}

# theme — switch the active base16 theme (per-machine; no git diff).
#   theme            fzf-pick from available themes
#   theme <slug>     set directly
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
  _chezmoi_set_data theme "$slug" "$cfg" || return 1
  chezmoi apply || return 1
  # cmux reads ~/.config/ghostty/config directly; repaint running sessions live.
  command -v cmux >/dev/null 2>&1 && cmux reload-config >/dev/null 2>&1
  echo "theme → ${slug}.  cmux repaints live; new shells, ghostty windows, zellij & nvim need a restart to fully apply."
  # Reload only interactive terminals: from a headless caller (Raycast script
  # commands, cron) exec'ing an interactive zsh would strand a shell waiting
  # on stdin.
  if [[ -t 0 && -t 1 ]]; then
    exec zsh
  fi
}

# Tab completion: `theme <Tab>` lists the vendored slugs, `wallpaper <Tab>`
# its verbs. compinit is loaded earlier by 20-completion.zsh.
_theme_slugs() {
  local src
  src=$(chezmoi source-path 2>/dev/null) || return
  local -a themes
  themes=(${src}/.chezmoidata/themes/*.toml(:t:r))
  _describe 'theme' themes
}
compdef _theme_slugs theme

_wallpaper_verbs() {
  local -a actions
  actions=(on off toggle)
  _describe 'action' actions
}
compdef _wallpaper_verbs wallpaper

# wallpaper — toggle the themed terminal background image (machine-local; no git
# diff). Pairs with the active theme via .chezmoidata/wallpaper.toml.
#   wallpaper on | off | toggle   (bare `wallpaper` = toggle)
wallpaper() {
  emulate -L zsh
  local cfg action cur next
  command -v chezmoi >/dev/null 2>&1 || { echo "wallpaper: chezmoi not found" >&2; return 1; }
  cfg=${CHEZMOI_CONFIG:-$HOME/.config/chezmoi/chezmoi.toml}
  [[ -f $cfg ]] || { echo "wallpaper: missing $cfg" >&2; return 1; }
  action=${1:-toggle}
  case $action in
    on|off) next=$action ;;
    toggle)
      cur=$(awk -F'"' '
        /^[[:space:]]*\[/ { indata = ($0 ~ /^[[:space:]]*\[data\][[:space:]]*$/); next }
        indata && /^[[:space:]]*wallpaper_mode[[:space:]]*=/ { print $2; exit }
      ' "$cfg")
      [[ $cur == off ]] && next=on || next=off
      ;;
    *) echo "usage: wallpaper on|off|toggle" >&2; return 1 ;;
  esac
  _chezmoi_set_data wallpaper_mode "$next" "$cfg" || return 1
  chezmoi apply || return 1
  command -v cmux >/dev/null 2>&1 && cmux reload-config >/dev/null 2>&1
  echo "wallpaper → ${next}"
}
