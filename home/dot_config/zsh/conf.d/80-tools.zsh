# Zoxide (guarded): `z <dir>` jumps by frecency; `zz` is interactive.
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh --cmd z)"
fi


# doctor: read-only health check, from the checkout chezmoi applies from.
doctor() {
  local src
  src=$(chezmoi source-path 2>/dev/null) || { echo "doctor: chezmoi not set up" >&2; return 1; }
  sh "${src:h}/scripts/doctor.sh" "$@"
}
