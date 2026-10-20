#!/bin/sh
# One-time: keep a pre-existing ~/.ssh/config as ~/.ssh/config.local (the
# include) before chezmoi manages it; never clobbers an existing one.
set -eu
cfg="$HOME/.ssh/config"
local_cfg="$HOME/.ssh/config.local"
if [ -f "$cfg" ] && [ ! -f "$local_cfg" ]; then
	cp "$cfg" "$local_cfg"
	chmod 600 "$local_cfg"
	echo "ssh: preserved pre-existing config as ~/.ssh/config.local"
fi
