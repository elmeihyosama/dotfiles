# mise: cd-aware activation for interactive shells (shims are in ~/.zshenv).
if command -v mise >/dev/null 2>&1; then
  # Cache `mise activate zsh` (a ~12 ms fork); the per-prompt hook still runs.
  # The raw output bakes the generating shell's PATH in as literals, which
  # would reset every later shell's PATH: generate from a clean mise state,
  # drop the PATH export (00-env put the shims first) and take
  # __MISE_ORIG_PATH from the sourcing shell. The first line is the key
  # (binary path + cache version); regenerate when it or the binary changes.
  _mise_activate="${ZSH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/mise/activate.zsh"
  _mise_key="# dotfiles 49-mise activate cache v2: ${commands[mise]}"
  _mise_line=""
  [[ -s "$_mise_activate" ]] && read -r _mise_line <"$_mise_activate"
  if [[ "$_mise_line" != "$_mise_key" || "$_mise_activate" -ot ${commands[mise]:A} ]]; then
    # Only a non-empty generation replaces the cache (temp file + rename): a
    # key over nothing would match next time and leave shells unactivated.
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

  # Completions: the pinned mise binary ships none, so cache `mise completion
  # zsh` (regenerated when older than the binary, never per shell). compinit
  # already scanned fpath, so autoload/compdef it directly.
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
