# zsh-completions' functions on fpath before compinit (20-completion.zsh).
_zc="${XDG_DATA_HOME:-$HOME/.local/share}/sheldon/repos/github.com/zsh-users/zsh-completions/src"
[[ -d "$_zc" ]] && fpath=("$_zc" $fpath)
unset _zc

# forgit reads FORGIT_NO_ALIASES when sheldon loads it (30-sheldon.zsh), so it
# must be set before; 47-forgit.zsh defines the namespaced f* aliases instead.
export FORGIT_NO_ALIASES=1
