# Starship prompt (guarded so a missing binary never errors)
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi
