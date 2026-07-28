# Completion notifications — desktop notification (+ bell) when a foreground
# command runs longer than a threshold. Delivered via OSC 777 to the tty, which
# ghostty forwards to the local desktop (over SSH included). Tune in 90-local:
#   NOTIFY_THRESHOLD=30        # seconds
#   NOTIFY_EXCLUDE=(ssh nvim …) # command basenames to skip
zmodload zsh/datetime 2>/dev/null

: ${NOTIFY_THRESHOLD:=30}
typeset -ga NOTIFY_EXCLUDE
(( ${#NOTIFY_EXCLUDE} )) || NOTIFY_EXCLUDE=(
  ssh nvim vim less man watch top htop btop tig lazygit lazydocker fzf yazi ff sz
)

# _notify TITLE BODY — OSC 777 desktop notification + bell to the tty. No-op if
# there is no writable tty. Reusable by other code.
_notify() {
  local tty=${TTY:-/dev/tty}
  [[ -w $tty ]] || return 0
  local title=${${1//[[:cntrl:]]/}//;/:}
  local body=${${2//[[:cntrl:]]/}//;/:}
  # Single redirect (not two separate `>`s) — a second `>` to the same regular
  # file would truncate away the first printf's bytes. Harmless on a real tty
  # (no truncation semantics there) but breaks tests that mock TTY as a file.
  { printf '\033]777;notify;%s;%s\a' "$title" "$body"; printf '\a'; } > "$tty"
}

_notify_preexec() { _notify_start=$EPOCHSECONDS; _notify_cmd=$1; }

_notify_precmd() {
  local ret=$?
  if [[ -n ${_notify_start:-} ]]; then
    local elapsed=$(( EPOCHSECONDS - _notify_start ))
    local full=$_notify_cmd
    unset _notify_start _notify_cmd
    # Strip leading wrappers / env-assignments so `sudo nvim`, `time btop`,
    # `NODE_ENV=x node` match the exclude list on the real command.
    local -a _w=(${(z)full})
    while (( ${#_w} )) && [[ ${_w[1]} == (sudo|doas|command|builtin|exec|time|nice|env) || ${_w[1]} == *=* ]]; do
      _w=(${_w[2,-1]})
    done
    local base=${_w[1]:t}
    if (( elapsed >= NOTIFY_THRESHOLD )) && [[ -n $base ]] \
      && ! (( ${NOTIFY_EXCLUDE[(Ie)$base]} )); then
      local glyph; (( ret == 0 )) && glyph="✓" || glyph="✗"
      local body=$full; (( ${#body} > 60 )) && body="${body[1,57]}…"
      _notify "${glyph} ${base} (${elapsed}s)" "$body"
    fi
  fi
  return $ret     # preserve $? for downstream precmd hooks (atuin/starship)
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _notify_preexec
add-zsh-hook precmd  _notify_precmd
# Run our precmd FIRST so it reads the command's real $? before atuin/starship
# recompute it; it returns $? unchanged, so those hooks still see the status.
precmd_functions=(_notify_precmd ${precmd_functions:#_notify_precmd})
