# Starship prompt (guarded so a missing binary never errors); its config is
# ~/.config/starship.toml (home/dot_config/starship.toml.tmpl).
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi
