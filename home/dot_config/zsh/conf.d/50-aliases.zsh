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

# sz — fuzzy project → zellij session (sessionizer). Resolves the repo script
# via chezmoi like the `theme` function does.
sz() {
  emulate -L zsh
  local src script
  src=$(chezmoi source-path 2>/dev/null) || { echo "sz: chezmoi not found" >&2; return 1; }
  script="${src:h}/scripts/sessionize.sh"
  [[ -x $script ]] || { echo "sz: $script not found" >&2; return 1; }
  "$script" "$@"
}

# fastfetch splash — ssh sessions get the red-hostname variant.
if command -v fastfetch >/dev/null 2>&1; then
  ff() {
    local cfg=~/.config/fastfetch/config.jsonc
    [[ -n ${SSH_TTY:-}${SSH_CONNECTION:-} ]] && cfg=~/.config/fastfetch/config-ssh.jsonc
    fastfetch --config "$cfg" "$@"
  }

  # Splash rules: inside zellij, only the first pane of a session (flag file
  # in tmp, so a reboot naturally resets it); outside zellij, every new
  # top-level shell (SHLVL guard keeps splits/subshells quiet).
  if [[ -o interactive ]]; then
    if [[ -n $ZELLIJ ]]; then
      () {
        local flag="${TMPDIR:-/tmp}/fastfetch-shown-${ZELLIJ_SESSION_NAME:-default}-${USER}"
        [[ -f $flag ]] && return
        ff
        : >| "$flag" 2>/dev/null
      }
    elif [[ $SHLVL -eq 1 ]]; then
      ff
    fi
  fi
fi
