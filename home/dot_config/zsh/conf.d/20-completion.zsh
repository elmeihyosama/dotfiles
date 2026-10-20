autoload -Uz compinit
# The (#qN.mh+24) glob qualifier below needs EXTENDED_GLOB.
setopt LOCAL_OPTIONS EXTENDED_GLOB
_zcd="${XDG_CACHE_HOME:-$HOME/.cache}/zcompdump"
if [[ -n "$_zcd"(#qN.mh+24) ]]; then
  compinit -d "$_zcd"
else
  compinit -C -d "$_zcd"
fi
unset _zcd

# Case-insensitive, then partial-word after ._-, then substring (cfg->config).
zstyle ':completion:*' matcher-list '' \
  'm:{a-zA-Z}={A-Za-z}' \
  'r:|[._-]=* r:|=*' \
  'l:|=*'
