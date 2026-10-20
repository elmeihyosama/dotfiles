#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Switch Theme
# @raycast.mode silent
#
# Optional parameters:
# @raycast.icon 🎨
# @raycast.packageName Dotfiles
# @raycast.argument1 { "type": "text", "placeholder": "slug (e.g. rose-pine-moon)" }
#
# Documentation:
# @raycast.description Switch the base16 theme across the whole stack

# mise reads the dotfiles pins/lock from this dir (also set in .zshenv).
export MISE_SYSTEM_CONFIG_DIR="$HOME/.config/mise-dotfiles"

# Interactive zsh so conf.d loads and the `theme` function exists. The slug
# rides as a positional parameter, never interpolated into the command string.
exec zsh -ic 'theme "$1"' -- "$1"
