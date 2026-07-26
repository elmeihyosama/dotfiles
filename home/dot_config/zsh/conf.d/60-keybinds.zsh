# vi-mode keymap + KEYTIMEOUT are set early in 00-env so all tools bind into a
# known viins main. Up-arrow is intentionally left to atuin (bound in 35-atuin);
# keep only down-arrow prefix-search here.
bindkey -M viins "^[[B" history-search-forward
bindkey -M vicmd "^[[B" history-search-forward

# Insert-mode emacs-style line-editing shortcuts
bindkey -M viins "^A" beginning-of-line
bindkey -M viins "^E" end-of-line
bindkey -M viins "^W" backward-kill-word
bindkey -M viins "^H" backward-kill-word   # Ctrl-Backspace
# NOTE: ^R is owned by atuin (bound in 35-atuin; fzf's own ^R bind is suppressed
# in 40-fzf). Do not rebind ^R here.

# Accept autosuggestion (insert mode)
bindkey -M viins '^ ' autosuggest-accept
