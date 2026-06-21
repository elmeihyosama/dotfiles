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
