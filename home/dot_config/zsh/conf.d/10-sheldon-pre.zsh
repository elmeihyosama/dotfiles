# Make zsh-completions' functions visible to compinit (compinit runs in 20-completion.zsh).
# sheldon clones plugins under its data dir; add the completions src to fpath.
_zc="${XDG_DATA_HOME:-$HOME/.local/share}/sheldon/repos/github.com/zsh-users/zsh-completions/src"
[[ -d "$_zc" ]] && fpath=("$_zc" $fpath)
unset _zc

# forgit reads FORGIT_NO_ALIASES at plugin-load time (guards its own `alias`
# registration inside forgit.plugin.zsh), so this MUST be set before sheldon
# loads plugins in 30-sheldon.zsh. See 47-forgit.zsh for the namespaced f*
# aliases that replace forgit's defaults.
export FORGIT_NO_ALIASES=1
