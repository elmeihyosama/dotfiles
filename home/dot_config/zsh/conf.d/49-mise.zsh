# mise — per-project tool versions + env + tasks. Dynamic activation (cd-aware)
# for interactive shells; shims for non-interactive live in ~/.zshenv.
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"

  # Completions.
  #
  # On macOS (Homebrew install, see Task 1) the `mise` formula already
  # symlinks a static `_mise` completion function into
  # /opt/homebrew/share/zsh/site-functions, which is a default zsh fpath
  # component scanned by `compinit` in 20-completion.zsh — that file loads
  # at position 20, before this one (49), so it's already picked up with
  # zero code here and without touching the 24h zcompdump cache at all.
  #
  # On Linux (mise installed via ubi as a bare static binary, no package
  # manager involved) there is no such file anywhere, so provide a portable
  # fallback: cache `mise completion zsh` to a stable fpath dir, regenerated
  # only when missing/empty or older than the mise binary (so an upgrade
  # doesn't leave a stale completion behind) — never on every shell, which
  # keeps the zcompdump cache honest and avoids a second `mise` subprocess
  # fork on every prompt.
  #
  # Because this file runs after compinit already scanned fpath for this
  # session, a freshly-written file here wouldn't ride that scan — so
  # `autoload`/`compdef` it directly instead of waiting for the next full
  # compinit rebuild. This is cheap (a local file read, no subprocess) and
  # works identically whether the cache already existed or was just created.
  _mise_comp_dir="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/completions"
  if [[ ! -s "$_mise_comp_dir/_mise" || "$_mise_comp_dir/_mise" -ot ${commands[mise]:A} ]]; then
    mkdir -p "$_mise_comp_dir"
    mise completion zsh >| "$_mise_comp_dir/_mise" 2>/dev/null
  fi
  if [[ -s "$_mise_comp_dir/_mise" ]]; then
    fpath=("$_mise_comp_dir" $fpath)
    autoload -Uz _mise
    compdef _mise mise
  fi
  unset _mise_comp_dir
fi
