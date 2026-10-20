#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Dotfiles Doctor
# @raycast.mode fullOutput
#
# Optional parameters:
# @raycast.icon 🩺
# @raycast.packageName Dotfiles
#
# Documentation:
# @raycast.description Read-only health check of this machine's provisioning

# Raycast does not read .zshenv before zsh starts; mise needs the dotfiles config dir.
export MISE_SYSTEM_CONFIG_DIR="$HOME/.config/mise-dotfiles"
exec zsh -ic doctor
