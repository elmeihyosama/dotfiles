# clip: copy stdin (or args) to the LOCAL clipboard: a native tool locally,
# else OSC 52 (works over SSH via ghostty). Copy only.
#   pwd | clip        cmd | clip        clip < file        clip foo bar
clip() {
  emulate -L zsh
  local data
  if (( $# )); then data="$*"; else data="$(cat)"; fi
  # Local with a native tool: no size limit, no mux quirks.
  if [[ -z ${SSH_CONNECTION:-}${SSH_TTY:-} ]]; then
    if command -v pbcopy >/dev/null 2>&1; then print -rn -- "$data" | pbcopy; return; fi
    if command -v wl-copy >/dev/null 2>&1; then print -rn -- "$data" | wl-copy; return; fi
    if command -v xclip  >/dev/null 2>&1; then print -rn -- "$data" | xclip -selection clipboard; return; fi
  fi
  local tty=${TTY:-/dev/tty}
  [[ -w $tty ]] || { print -u2 "clip: no writable tty for OSC 52"; return 1; }
  local b64; b64=$(print -rn -- "$data" | base64 | tr -d '\n')
  printf '\033]52;c;%s\a' "$b64" > "$tty"
}
# Muscle-memory alias only where the real pbcopy does not exist (never shadow it).
command -v pbcopy >/dev/null 2>&1 || alias pbcopy='clip'
