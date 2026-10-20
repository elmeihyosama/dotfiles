# forgit (fzf git ops), namespaced under f* so nothing shadows the git aliases.
# FORGIT_NO_ALIASES is set in 10-sheldon-pre.zsh: here would be too late.
# This forgit names compound functions with `::` (forgit::checkout::branch).
if (( ${+functions[forgit::add]} )); then
  alias fga='forgit::add'                  # fuzzy stage hunks/files
  alias fgd='forgit::diff'                 # fuzzy diff a file/commit
  alias flog='forgit::log'                 # fuzzy log browser
  alias fcb='forgit::checkout::branch'     # fuzzy checkout branch
  alias fcf='forgit::checkout::file'       # fuzzy restore/discard a file
  alias fst='forgit::stash::show'          # stash picker
fi
