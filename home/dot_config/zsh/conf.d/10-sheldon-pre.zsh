# Make zsh-completions' functions visible to compinit (compinit runs in 20-completion.zsh).
# sheldon clones plugins under its data dir; add the completions src to fpath.
_zc="${XDG_DATA_HOME:-$HOME/.local/share}/sheldon/repos/github.com/zsh-users/zsh-completions/src"
[[ -d "$_zc" ]] && fpath=("$_zc" $fpath)
unset _zc
