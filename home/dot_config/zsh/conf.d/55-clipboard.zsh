# clip — copy stdin (or args) to the LOCAL clipboard. Uses a native tool when
# local; emits OSC 52 (works over SSH, forwarded by ghostty) otherwise. Copy
# only — pasting stays ⌘V (ghostty prompts on OSC 52 reads).
#   pwd | clip        cmd | clip        clip < file        clip foo bar
clip() {
  emulate -L zsh
  local data
  if (( $# )); then data="$*"; else data="$(cat)"; fi
  # Local (no SSH) with a native tool → use it (no size limit, no mux quirks).
  if [[ -z ${SSH_CONNECTION:-}${SSH_TTY:-} ]]; then
    if command -v pbcopy >/dev/null 2>&1; then print -rn -- "$data" | pbcopy; return; fi
    if command -v wl-copy >/dev/null 2>&1; then print -rn -- "$data" | wl-copy; return; fi
    if command -v xclip  >/dev/null 2>&1; then print -rn -- "$data" | xclip -selection clipboard; return; fi
  fi
  # Otherwise (SSH, or no native tool) → OSC 52 to the tty.
  local tty=${TTY:-/dev/tty}
  [[ -w $tty ]] || { print -u2 "clip: no writable tty for OSC 52"; return 1; }
  local b64; b64=$(print -rn -- "$data" | base64 | tr -d '\n')
  printf '\033]52;c;%s\a' "$b64" > "$tty"
}
# Muscle-memory alias only where the real pbcopy does not exist (never shadow it).
command -v pbcopy >/dev/null 2>&1 || alias pbcopy='clip'
