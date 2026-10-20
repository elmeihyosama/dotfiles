"""Stub dotfiles CLI for the TUI tests: records each call, prints fixtures.

STUB_LOG: file that gets one JSON argv per call.
STUB_FAIL: a subcommand that exits 1 (after printing a FAIL line).
STUB_LIST: replaces the `list --json` output verbatim.
"""

import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(json.dumps(args) + "\n")
sub = args[0] if args else ""
if sub == os.environ.get("STUB_FAIL"):
    print(f"FAIL  stub {sub} failed")
    sys.exit(1)

TOOLS = [
    {
        "name": "fzf",
        "group": "core",
        "bin": "fzf",
        "source": "mise",
        "selected": True,
        "installed": True,
        "pinned": "0.70.0",
        "actual": "0.70.0",
    },
    {
        "name": "ripgrep",
        "group": "core",
        "bin": "rg",
        "source": "mise",
        "selected": True,
        "installed": True,
        "pinned": "15.1.0",
        "actual": "14.0.0",
    },
    {
        "name": "lazygit",
        "group": "git",
        "bin": "lazygit",
        "source": "mise",
        "selected": False,
        "installed": False,
        "pinned": "0.60.0",
        "actual": None,
    },
    {
        "name": "zellij",
        "group": "terminal",
        "bin": "zellij",
        "source": "native",
        "selected": True,
        "installed": False,
        "pinned": None,
        "actual": None,
    },
]
PAL = {f"base0{c}": f"#{i:02x}{i:02x}{i:02x}" for i, c in enumerate("0123456789ABCDEF")}
LIGHT = {**PAL, "base00": "#f5f5f7", "base05": "#1d1d1f"}

if args == ["list", "--json"]:
    print(os.environ.get("STUB_LIST") or json.dumps(TOOLS))
elif args == ["look", "--json"]:
    current = os.environ.get("STUB_THEME", "dark-one")
    print(
        json.dumps(
            {
                "theme": current,
                "glass": None,
                "levels": ["clear", "frosted", "solid", "default"],
                "themes": [{"slug": "dark-one", "colors": PAL}, {"slug": "light-two", "colors": LIGHT}],
            }
        )
    )
elif sub == "doctor":
    print("OK    user-local bin dir on PATH")
    print("OK    mise 2026.10.11")
    print("WARN  fzf also installed at /opt/homebrew/bin/fzf (shadowed)")
    print("FAIL  zellij missing")
    print("doctor: 1 failure(s)")
    sys.exit(1)
elif args == ["update", "--check"]:
    print("==> incoming commits")
    print("abc1234 a change")
else:
    print("applied " + " ".join(args))
