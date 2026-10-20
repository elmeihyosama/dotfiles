# vi-mode is set in 00-env; Up-arrow and ^R belong to atuin (35-atuin), so
# only down-arrow prefix search here.
bindkey -M viins "^[[B" history-search-forward
bindkey -M vicmd "^[[B" history-search-forward

# Insert-mode emacs-style line-editing shortcuts
bindkey -M viins "^A" beginning-of-line
bindkey -M viins "^E" end-of-line
bindkey -M viins "^W" backward-kill-word
bindkey -M viins "^H" backward-kill-word   # Ctrl-Backspace

# Accept autosuggestion (insert mode)
bindkey -M viins '^ ' autosuggest-accept
