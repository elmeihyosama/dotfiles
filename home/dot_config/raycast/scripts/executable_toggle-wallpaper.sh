#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Toggle Wallpaper
# @raycast.mode silent
#
# Optional parameters:
# @raycast.icon 🖼️
# @raycast.packageName Dotfiles
#
# Documentation:
# @raycast.description Toggle the themed terminal background image

# Raycast skips .zshenv; mise needs the dotfiles config dir.
export MISE_SYSTEM_CONFIG_DIR="$HOME/.config/mise-dotfiles"
exec zsh -ic "wallpaper toggle"
