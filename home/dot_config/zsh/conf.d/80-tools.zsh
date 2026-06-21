# Zoxide (guarded). `z <dir>` to jump by frecency; `zz` for interactive (see aliases).
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh --cmd z)"
fi

# navi cheatsheets are available as the `navi` command (no key widget, by preference).
