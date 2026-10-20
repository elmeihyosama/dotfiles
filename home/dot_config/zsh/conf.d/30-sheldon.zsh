# sheldon plugins (order in plugins.toml; fast-syntax-highlighting last so it
# wraps every widget).
if command -v sheldon >/dev/null 2>&1; then
  # Cache `sheldon source` (a fork); its output only points at plugin files,
  # so only a plugins.toml change or a sheldon upgrade needs a regen.
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
