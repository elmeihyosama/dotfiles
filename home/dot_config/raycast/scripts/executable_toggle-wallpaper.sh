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

exec zsh -ic "wallpaper toggle"
