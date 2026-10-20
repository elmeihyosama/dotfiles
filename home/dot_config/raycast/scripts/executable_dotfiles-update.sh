#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Dotfiles Update
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.icon 🔄
# @raycast.packageName Dotfiles
#
# Documentation:
# @raycast.description Pull, provision and verify this machine (dotfiles update)

# Raycast does not read .zshenv before zsh starts; mise needs the dotfiles config dir.
export MISE_SYSTEM_CONFIG_DIR="$HOME/.config/mise-dotfiles"
exec zsh -ic 'dotfiles update'
