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

# _ghostty_usr2_ok: true when Ghostty is 1.2+, which reloads config on SIGUSR2.
_ghostty_usr2_ok() {
  local g v
  g=${commands[ghostty]:-/Applications/Ghostty.app/Contents/MacOS/ghostty}
  [[ -x $g ]] || return 1
  v=$($g --version 2>/dev/null | command head -1)
  [[ $v =~ '^Ghostty ([0-9]+)\.([0-9]+)' ]] || return 1
  (( match[1] > 1 || (match[1] == 1 && match[2] >= 2) ))
}

# _theme_live_reload: repaint running apps after `chezmoi apply`: nvim over RPC
# (THEME_NVIM_GLOB overrides the socket glob), cmux, Ghostty via SIGUSR2;
# zellij reloads config.kdl itself. Under DOTFILES_TEST the default globs and
# the signal need THEME_TEST_DEFAULT_GLOB / THEME_TEST_SIGNAL.
_theme_live_reload() {
  emulate -L zsh
  local -a socks
  local r n=0 line
  if [[ -n ${THEME_NVIM_GLOB-} ]]; then
    socks=(${~THEME_NVIM_GLOB}(N=))
  elif [[ -z ${DOTFILES_TEST-} || -n ${THEME_TEST_DEFAULT_GLOB-} ]]; then
    # macOS: $TMPDIR/nvim.$USER/*/; Linux: $XDG_RUNTIME_DIR/. Both roots.
    for r in ${${TMPDIR:-/tmp}%/} ${XDG_RUNTIME_DIR%/}; do
      socks+=($r/nvim.${USER}/*/nvim.*.0(N=) $r/nvim.*.0(N=))
    done
    socks=(${(u)socks})
  fi
  if (( ${#socks} )) && command -v nvim >/dev/null 2>&1; then
    # In $(...) so its jobs stay out of the caller's job table; 2s watchdog
    # per socket (stock macOS has no timeout(1)). No comments inside: an
    # interactive shell parses $(...) without interactive_comments.
    n=$(
      c=0
      for s in $socks; do
        nvim --server $s --remote-expr 'luaeval("require(\"config.theme_reload\").reload()")' >/dev/null 2>&1 &
        pid=$!
        { sleep 2; kill $pid } >/dev/null 2>&1 &
        wd=$!
        wait $pid 2>/dev/null && (( ++c ))
        kill $wd 2>/dev/null
      done
      print $c
    )
  fi
  # cmux reads ~/.config/ghostty/config directly.
  command -v cmux >/dev/null 2>&1 && cmux reload-config >/dev/null 2>&1
  line="reloaded $n nvim"
  if [[ -z ${DOTFILES_TEST-} || -n ${THEME_TEST_SIGNAL-} ]] &&
    pgrep -u "$USER" -x ghostty >/dev/null 2>&1; then
    # SIGUSR2 kills a Ghostty older than 1.2 (no handler): only signal 1.2+.
    if _ghostty_usr2_ok && pkill -USR2 -u "$USER" -x ghostty 2>/dev/null; then
      line+="; ghostty: reloaded"
    else
      line+="; ghostty: press ⌘⇧, (or ctrl+shift+, on Linux) to apply"
    fi
  fi
  print -r -- $line
  # Live sessions only; list-sessions also shows EXITED (resurrectable) ones.
  if command -v zellij >/dev/null 2>&1 &&
    zellij list-sessions -n 2>/dev/null | command grep '\[Created' | command grep -qv EXITED; then
    print -r -- "zellij: applied"
  fi
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
