# mise — per-project tool versions + env + tasks. Dynamic activation (cd-aware)
# for interactive shells; shims for non-interactive live in ~/.zshenv.
if command -v mise >/dev/null 2>&1; then
  # Cache `mise activate zsh` (a binary fork, ~12 ms) to a file and re-source
  # it. This caches the activation-script GENERATION only — the runtime
  # `_mise_hook` (cd-aware env resolve) still runs each prompt exactly as
  # before, so per-project env is unchanged.
  #
  # The raw output is not shell-independent: it bakes the generating shell's
  # PATH in as literals (`export PATH='<shims>:<that PATH>'`,
  # `export __MISE_ORIG_PATH='<that PATH>'`, plus a deactivate preamble when
  # generated under an activated shell). Replayed, that resets every later
  # shell's PATH to one old snapshot and drops its own entries (per-session
  # dirs, a venv). So generate it from a clean mise state, drop the PATH
  # export (00-env already put the shims first) and take __MISE_ORIG_PATH from
  # the sourcing shell, as a live `eval "$(mise activate zsh)"` would.
  #
  # Regenerate when missing, older than the mise binary, or written for a
  # different binary or by an older version of this file (the first line is
  # the key: the output embeds the binary's absolute path).
  _mise_activate="${ZSH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/mise/activate.zsh"
  _mise_key="# dotfiles 49-mise activate cache v2: ${commands[mise]}"
  _mise_line=""
  [[ -s "$_mise_activate" ]] && read -r _mise_line <"$_mise_activate"
  if [[ "$_mise_line" != "$_mise_key" || "$_mise_activate" -ot ${commands[mise]:A} ]]; then
    # Only a successful, non-empty generation replaces the cache (written to
    # a temp file, then renamed over it): a key line over nothing would match
    # next time and leave every shell unactivated. On failure the previous
    # cache stays and is sourced below; its stale key retries next shell.
    if _mise_out="$(env -u MISE_SHELL -u __MISE_DIFF -u __MISE_SESSION -u __MISE_ORIG_PATH \
        -u __MISE_ZSH_ACTIVATE_PATH -u __MISE_ZSH_ACTIVATE_ENV mise activate zsh)" &&
      [[ -n "$_mise_out" ]]; then
      mkdir -p "${_mise_activate:h}"
      {
        print -r -- "$_mise_key"
        print -r -- "$_mise_out" |
          sed -e '/^export PATH=/d' \
            -e 's/^export __MISE_ORIG_PATH=.*/export __MISE_ORIG_PATH="$PATH"/'
      } >| "$_mise_activate.$$" && mv -f "$_mise_activate.$$" "$_mise_activate"
    fi
  fi
  [[ -s "$_mise_activate" ]] && source "$_mise_activate"
  unset _mise_activate _mise_key _mise_line _mise_out

  # Completions.
  #
  # A Homebrew `mise` formula (if the user has one) symlinks a static
  # `_mise` completion function into /opt/homebrew/share/zsh/site-functions,
  # a default zsh fpath component scanned by `compinit` in 20-completion.zsh — that file loads
  # at position 20, before this one (49), so it's already picked up with
  # zero code here and without touching the 24h zcompdump cache at all.
  #
  # The dotfiles install mise as a bare pinned binary (ansible/tasks/mise.yml,
  # every OS), which ships no completion file, so provide a portable
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
