# _chezmoi_set_data KEY VALUE CFG: set `KEY = "VALUE"` in the chezmoi config's
# [data] table (replacing it, inserting it, or adding [data]). Writes in place
# to keep mode/inode/symlink. KEY must be literal: it goes into an awk regex.
_chezmoi_set_data() {
  local key=$1 val=$2 cfg=$3 tmp
  # A double-quote in VAL would emit malformed TOML.
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

# theme: switch the active base16 theme (per-machine; no git diff).
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
  echo "theme → ${slug}"
  _theme_live_reload
  # Only interactive terminals: a headless caller (Raycast, cron) exec'ing an
  # interactive zsh would strand a shell waiting on stdin.
  if [[ -t 0 && -t 1 ]]; then
    exec zsh
  fi
}

# `theme <Tab>` lists the slugs, `wallpaper <Tab>` its verbs.
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

# wallpaper: toggle the themed terminal background (machine-local; no git diff).
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
  echo "wallpaper → ${next}"
  _theme_live_reload
}

# _theme_live_reload: repaint running apps after `chezmoi apply`. nvim over RPC
# (THEME_NVIM_GLOB overrides the socket glob), cmux via reload-config; zellij
# reloads config.kdl itself; Ghostty needs its reload key.
_theme_live_reload() {
  emulate -L zsh
  setopt no_monitor no_notify
  local -a socks
  if [[ -n ${THEME_NVIM_GLOB-} ]]; then
    socks=(${~THEME_NVIM_GLOB}(N=))
  else
    socks=(${XDG_RUNTIME_DIR:-${${TMPDIR:-/tmp}%/}}/nvim.${USER}/*/nvim.*.0(N=))
    [[ -n ${XDG_RUNTIME_DIR-} ]] && socks+=($XDG_RUNTIME_DIR/nvim.*.0(N=))
  fi
  local s pid wd n=0
  if (( ${#socks} )) && command -v nvim >/dev/null 2>&1; then
    for s in $socks; do
      nvim --server $s --remote-expr 'luaeval("require(\"config.theme_reload\").reload()")' >/dev/null 2>&1 &
      pid=$!
      # 2s watchdog (no `timeout` on stock macOS): a hung nvim never answers.
      { sleep 2; kill $pid } >/dev/null 2>&1 &
      wd=$!
      wait $pid 2>/dev/null && (( ++n ))
      kill $wd 2>/dev/null
    done
  fi
  # cmux reads ~/.config/ghostty/config directly.
  command -v cmux >/dev/null 2>&1 && cmux reload-config >/dev/null 2>&1
  print -r -- "reloaded $n nvim; ghostty: press ⌘⇧, (or ctrl+shift+, on Linux) to apply"
  command -v zellij >/dev/null 2>&1 && print -r -- "zellij: applied"
  return 0
}

# glass: set the Ghostty translucency level (machine-local; no git diff).
#   glass clear|frosted|tinted|solid|default|off   (off = default)
#   glass            fzf-pick, else usage
# Levels come from .chezmoidata/glass.toml.
glass() {
  emulate -L zsh
  local cfg level lv
  command -v chezmoi >/dev/null 2>&1 || { echo "glass: chezmoi not found" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "glass: jq not found" >&2; return 1; }
  cfg=${CHEZMOI_CONFIG:-$HOME/.config/chezmoi/chezmoi.toml}
  [[ -f $cfg ]] || { echo "glass: missing $cfg" >&2; return 1; }
  local -a levels
  levels=(${(f)"$(chezmoi data --format json 2>/dev/null | jq -r '.glass_levels // {} | keys_unsorted[]')"})
  (( ${#levels} )) || { echo "glass: no levels in chezmoi data" >&2; return 1; }
  if (( $# )); then
    level=$1
  elif command -v fzf >/dev/null 2>&1; then
    level=$(print -l -- $levels off | fzf --prompt='glass ❯ ' --height 40% --reverse) || return 0
  else
    echo "usage: glass ${(j:|:)levels}|off" >&2; print -l -- $levels off >&2; return 1
  fi
  [[ -z $level ]] && return 0
  [[ $level == off ]] && level=default
  if (( ! ${levels[(Ie)$level]} )); then
    echo "glass: unknown level '${level}'" >&2
    echo "usage: glass ${(j:|:)levels}|off" >&2; print -l -- $levels off >&2; return 1
  fi
  _chezmoi_set_data glass "$level" "$cfg" || return 1
  chezmoi apply || return 1
  echo "glass → ${level}"
  _theme_live_reload
}

_glass_levels() {
  local -a levels
  levels=(${(f)"$(chezmoi data --format json 2>/dev/null | jq -r '.glass_levels // {} | keys_unsorted[]')"} off)
  _describe 'level' levels
}
compdef _glass_levels glass
