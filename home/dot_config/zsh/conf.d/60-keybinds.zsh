# vi-mode line editing
bindkey -v
export KEYTIMEOUT=1   # snappy Esc->normal-mode switch (default ~0.4s feels laggy)

# Prefix history search on up/down, in BOTH insert (viins) and normal (vicmd) keymaps
for _km in viins vicmd; do
  bindkey -M $_km "^[[A" history-search-backward
  bindkey -M $_km "^[[B" history-search-forward
done
unset _km

# Insert-mode emacs-style line-editing shortcuts
bindkey -M viins "^A" beginning-of-line
bindkey -M viins "^E" end-of-line
bindkey -M viins "^W" backward-kill-word
bindkey -M viins "^H" backward-kill-word   # Ctrl-Backspace
# NOTE: ^R is intentionally left to fzf's fuzzy-history widget (bound in 40-fzf
# across all keymaps). Do not rebind it here or it overrides fzf history.

# Accept autosuggestion (insert mode)
bindkey -M viins '^ ' autosuggest-accept
