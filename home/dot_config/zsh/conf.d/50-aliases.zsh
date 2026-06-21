# Navigation
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."

# Listing via eza (guarded). Standard commands (grep/find/cat/top) are NOT shadowed.
command -v eza >/dev/null 2>&1 && {
  alias ls="eza --icons=always --group-directories-first"
  alias ll="eza -la --icons=always --group-directories-first"
  alias tree="eza --tree --icons=always"
}

# Yazi with cd-on-exit
if command -v yazi >/dev/null 2>&1; then
  y() {
    local tmp cwd; tmp="$(mktemp -t yazi-cwd.XXXXXX)"
    yazi "$@" --cwd-file="$tmp"
    if cwd="$(command cat -- "$tmp")" && [[ -n "$cwd" && "$cwd" != "$PWD" ]]; then
      builtin cd -- "$cwd"
    fi
    rm -f -- "$tmp"
  }
fi

# Git shortcuts
alias g="git" gs="git status" gl="git log --oneline --graph --decorate" \
      ga="git add" gc="git commit" gp="git push" gco="git checkout"

# System info — non-shadowing names (do NOT override df/du/top)
command -v duf  >/dev/null 2>&1 && alias dfh="duf"
command -v dust >/dev/null 2>&1 && alias duh="dust"
command -v btop >/dev/null 2>&1 && alias bt="btop"

# Zoxide interactive (guarded)
command -v zoxide >/dev/null 2>&1 && alias zz="zoxide query --interactive"
