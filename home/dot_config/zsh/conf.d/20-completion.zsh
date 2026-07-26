autoload -Uz compinit
# The (#qN.mh+24) glob qualifier below requires EXTENDED_GLOB; set it locally
# so the 24h cache-reuse check works even if an earlier module unset it.
setopt LOCAL_OPTIONS EXTENDED_GLOB
_zcd="${XDG_CACHE_HOME:-$HOME/.cache}/zcompdump"
if [[ -n "$_zcd"(#qN.mh+24) ]]; then
  compinit -d "$_zcd"
else
  compinit -C -d "$_zcd"
fi
unset _zcd

# Fuzzy matching: case-insensitive, then partial-word after ._-, then substring.
# Feeds the existing fzf-tab menu — cfg->config, gco->git checkout, dtc->dot_config.
zstyle ':completion:*' matcher-list '' \
  'm:{a-zA-Z}={A-Za-z}' \
  'r:|[._-]=* r:|=*' \
  'l:|=*'
