# Starship prompt (guarded so a missing binary never errors)
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

# Cursor shape from the prompt options (`dotfiles prompt cursor=… blink=…`):
# ~/.config/zsh/cursor holds its DECSCUSR code, and only exists when the
# choice isn't Ghostty's own blinking bar (Ghostty's integration then stays
# out). Read at every prompt, so a change reaches open shells; vi command
# mode is a block; commands start with the terminal's configured cursor.
_cursor_draw() {
  local f=$HOME/.config/zsh/cursor c
  [[ -r $f ]] || return 0
  c=$(<$f)
  [[ $c == [1-6] ]] || return 0
  [[ $KEYMAP == vicmd ]] && c=$(( c % 2 ? 1 : 2 ))
  print -n "\e[${c} q"
}
_cursor_reset() {
  [[ -r $HOME/.config/zsh/cursor ]] && print -n '\e[0 q'
  return 0
}
autoload -Uz add-zle-hook-widget add-zsh-hook
add-zle-hook-widget zle-line-init _cursor_draw
add-zle-hook-widget zle-keymap-select _cursor_draw
add-zsh-hook preexec _cursor_reset
