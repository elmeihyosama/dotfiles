# Load all sheldon-managed plugins (order defined in plugins.toml;
# fast-syntax-highlighting is last so it wraps every widget).
if command -v sheldon >/dev/null 2>&1; then
  # Cache `sheldon source` (a binary fork) to a file; re-source that and only
  # regenerate when plugins.toml changes or the sheldon binary is upgraded.
  # sheldon's output is just `source` lines pointing at plugin repo files, so
  # plugin *updates* need no regen — only plugins.toml edits (which ride
  # `chezmoi apply`, bumping mtime) or a sheldon bump do.
  _sheldon_cache="${XDG_CACHE_HOME:-$HOME/.cache}/sheldon/source.zsh"
  _sheldon_toml="${XDG_CONFIG_HOME:-$HOME/.config}/sheldon/plugins.toml"
  if [[ ! -s "$_sheldon_cache" || "$_sheldon_toml" -nt "$_sheldon_cache" \
        || ${commands[sheldon]:A} -nt "$_sheldon_cache" ]]; then
    mkdir -p "${_sheldon_cache:h}"
    sheldon source >| "$_sheldon_cache"
  fi
  source "$_sheldon_cache"
  unset _sheldon_cache _sheldon_toml
fi
