# Zoxide (guarded). `z <dir>` to jump by frecency; `zz` for interactive (see aliases).
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh --cmd z)"
fi

# navi cheatsheets are available as the `navi` command (no key widget, by preference).

# doctor — read-only health check of this machine's provisioning (tools, font,
# chezmoi drift, theme, login shell). Lives in the repo; resolve it like `theme`.
doctor() {
  local src
  src=$(chezmoi source-path 2>/dev/null) || { echo "doctor: chezmoi not found" >&2; return 1; }
  sh "${src:h}/scripts/doctor.sh" "$@"
}
