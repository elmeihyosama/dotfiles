# Hand-rolled line-editor widgets. Bound in viins (+ vicmd for movement) since
# the shell is vi-mode. Loads after 60-keybinds; owns no history keys (atuin does).

# --- Ctrl-arrows: word movement. Alt-arrows are reserved for zellij tab/pane
#     nav, so word-jump lives on Ctrl-arrows (zellij passes these through). ---
for _km in viins vicmd; do
  bindkey -M $_km '^[[1;5C' forward-word    # Ctrl-Right
  bindkey -M $_km '^[[1;5D' backward-word   # Ctrl-Left
done
unset _km
# Word-delete on Alt-Backspace (zellij does not intercept it).
bindkey -M viins '^[^?' backward-kill-word

# --- Ctrl-Z: suspend, and resume a suspended job when the line is empty ---
_ctrlz() {
  if [[ -z $BUFFER ]]; then
    if jobs %- >/dev/null 2>&1 || jobs %+ >/dev/null 2>&1; then
      BUFFER='fg'
      zle accept-line
    fi
  else
    zle push-input
  fi
}
zle -N _ctrlz
bindkey -M viins '^Z' _ctrlz

# --- Ctrl-X Ctrl-E: edit the current command line in $EDITOR (nvim) ---
autoload -Uz edit-command-line
zle -N edit-command-line
bindkey -M viins '^X^E' edit-command-line
bindkey -M vicmd '^X^E' edit-command-line

# --- Path-segment-aware word ops: stop at / and . ---
# Default WORDCHARS makes word-delete swallow whole paths; trim separators.
WORDCHARS='*?_-[]~&;!#$%^(){}<>'

# --- take: mkdir -p then cd into it ---
take() {
  [[ -z $1 ]] && { print -u2 'take: need a directory'; return 1; }
  mkdir -p -- "$1" && cd -- "$1"
}
