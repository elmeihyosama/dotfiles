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

exec zsh -ic doctor
