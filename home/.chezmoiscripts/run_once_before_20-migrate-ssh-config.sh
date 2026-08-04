#!/bin/sh
# One-time: preserve any pre-existing ~/.ssh/config as the machine-local
# include (~/.ssh/config.local) before chezmoi starts managing ~/.ssh/config
# itself. Without this, the first apply would overwrite hand-written host
# blocks. Skipped if config.local already exists (nothing is ever clobbered).
set -eu
cfg="$HOME/.ssh/config"
local_cfg="$HOME/.ssh/config.local"
if [ -f "$cfg" ] && [ ! -f "$local_cfg" ]; then
	cp "$cfg" "$local_cfg"
	chmod 600 "$local_cfg"
	echo "ssh: preserved pre-existing config as ~/.ssh/config.local"
fi
