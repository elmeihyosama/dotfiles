# Desktop notification (+ bell) when a foreground command runs long, via OSC
# 777 (ghostty forwards it, over SSH too). Tune in 90-local:
#   NOTIFY_THRESHOLD=30        # seconds
#   NOTIFY_EXCLUDE=(ssh nvim …) # command basenames to skip
zmodload zsh/datetime 2>/dev/null

: ${NOTIFY_THRESHOLD:=30}
typeset -ga NOTIFY_EXCLUDE
(( ${#NOTIFY_EXCLUDE} )) || NOTIFY_EXCLUDE=(
  ssh nvim vim less man watch top htop btop tig lazygit lazydocker fzf yazi ff sz
)

# _notify TITLE BODY: OSC 777 + bell to the tty; no-op without one.
_notify() {
  local tty=${TTY:-/dev/tty}
  [[ -w $tty ]] || return 0
  local title=${${1//[[:cntrl:]]/}//;/:}
  local body=${${2//[[:cntrl:]]/}//;/:}
  # One redirect: a second `>` to a regular file (tests mock the tty) would
  # truncate the first printf.
  { printf '\033]777;notify;%s;%s\a' "$title" "$body"; printf '\a'; } > "$tty"
}

_notify_preexec() { _notify_start=$EPOCHSECONDS; _notify_cmd=$1; }

_notify_precmd() {
  local ret=$?
  if [[ -n ${_notify_start:-} ]]; then
    local elapsed=$(( EPOCHSECONDS - _notify_start ))
    local full=$_notify_cmd
    unset _notify_start _notify_cmd
    # Strip wrappers / env assignments (`sudo nvim`, `NODE_ENV=x node`).
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
# First, so it reads the command's real $? (and returns it unchanged).
precmd_functions=(_notify_precmd ${precmd_functions:#_notify_precmd})
