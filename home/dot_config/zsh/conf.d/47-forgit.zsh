# forgit — fzf-driven git ops (plugin loaded by sheldon). Namespaced under f*
# so nothing shadows the plain git aliases (ga/gco/gl/...). Uses FZF_DEFAULT_OPTS
# (themed) and git-delta previews automatically.
#
# FORGIT_NO_ALIASES is exported in 10-sheldon-pre.zsh (NOT here): forgit reads
# it at plugin-load time inside forgit.plugin.zsh (`[[ -z $FORGIT_NO_ALIASES ]]`
# guards its own alias registration), which happens in 30-sheldon.zsh — before
# this file loads. Setting it here would be too late.
#
# Verified against the installed wfxr/forgit plugin
# (~/.local/share/sheldon/repos/github.com/wfxr/forgit/forgit.plugin.zsh):
# this version namespaces compound function names with `::` throughout
# (forgit::checkout::branch, not forgit::checkout_branch), so the aliases
# below use the real names, not the task's placeholder names.
#
# Guard: only bind if forgit actually loaded (function defined).
if (( ${+functions[forgit::add]} )); then
  alias fga='forgit::add'                  # fuzzy stage hunks/files
  alias fgd='forgit::diff'                 # fuzzy diff a file/commit
  alias flog='forgit::log'                 # fuzzy log browser
  alias fcb='forgit::checkout::branch'     # fuzzy checkout branch
  alias fcf='forgit::checkout::file'       # fuzzy restore/discard a file
  alias fst='forgit::stash::show'          # stash picker
fi
