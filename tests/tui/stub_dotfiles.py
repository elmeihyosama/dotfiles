"""Stub dotfiles CLI for the TUI tests: records each call, prints fixtures.

STUB_LOG: file that gets one JSON argv per call.
STUB_FAIL: a subcommand that exits 1 (after printing a FAIL line).
STUB_LIST: replaces the `list --json` output verbatim.
STUB_PROC: file that gets one JSON {argv, pid, leader, prompt} per call.
STUB_SLOW: a full command line (e.g. "update") that sleeps 30s (quit/cancel tests).
STUB_BIG: a subcommand that prints 200 KB with no newline first.
STUB_THEME: the active theme slug in `look --json`.
STUB_WORST: worst realistic data everywhere (the WORST_* fixtures), for the
  break-the-UI pass and its screenshots.
"""

import json
import os
import sys
import time

args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as f:
    f.write(json.dumps(args) + "\n")
if proc_log := os.environ.get("STUB_PROC"):
    with open(proc_log, "a") as f:
        record = {
            "argv": args,
            "pid": os.getpid(),
            "leader": os.getsid(0) == os.getpid(),
            "prompt": os.environ.get("GIT_TERMINAL_PROMPT"),
        }
        f.write(json.dumps(record) + "\n")
sub = args[0] if args else ""
worst = bool(os.environ.get("STUB_WORST"))
if " ".join(args) == os.environ.get("STUB_SLOW"):
    print("started", flush=True)
    time.sleep(30)
if sub == os.environ.get("STUB_FAIL"):
    print(f"FAIL  stub {sub} failed")
    sys.exit(1)


def tool(name, group, source, selected, installed, pinned=None, actual=None):
    return {
        "name": name,
        "group": group,
        "bin": name,
        "source": source,
        "selected": selected,
        "installed": installed,
        "pinned": pinned,
        "actual": actual,
    }


TOOLS = [
    tool("fzf", "core", "mise", True, True, "0.70.0", "0.70.0"),
    tool("ripgrep", "core", "mise", True, True, "15.1.0", "14.0.0"),
    tool("lazygit", "git", "mise", False, False, "0.60.0"),
    tool("zellij", "terminal", "native", True, False),
]
# real palettes from the repo: catppuccin-mocha and iglass-light
PAL = dict(
    zip(
        [f"base0{c}" for c in "0123456789ABCDEF"],
        [
            "#1e1e2e",
            "#181825",
            "#313244",
            "#45475a",
            "#585b70",
            "#cdd6f4",
            "#f5e0dc",
            "#b4befe",
            "#f38ba8",
            "#fab387",
            "#f9e2af",
            "#a6e3a1",
            "#94e2d5",
            "#89b4fa",
            "#cba6f7",
            "#f2cdcd",
        ],
        strict=True,
    )
)
LIGHT = dict(
    zip(
        PAL,
        [
            "#f5f5f7",
            "#e5e5ea",
            "#bad7f9",
            "#605f64",
            "#3a3a3c",
            "#1d1d1f",
            "#1d1d1f",
            "#000000",
            "#92000b",
            "#c30006",
            "#763200",
            "#00521b",
            "#004a6e",
            "#0035bb",
            "#6a238a",
            "#902fbd",
        ],
        strict=True,
    )
)
THEMES = [
    {"slug": "dark-one", "colors": PAL},
    {"slug": "light-two", "colors": LIGHT},
    {"slug": "bad-hex", "colors": {**LIGHT, "base00": "#abc"}},
    "junk",
]
DOCTOR = [
    "OK    user-local bin dir on PATH",
    "OK    mise 2026.10.11",
    "WARN  fzf also installed at /opt/homebrew/bin/fzf (shadowed)",
    "FAIL  zellij missing",
    "doctor: 1 failure(s)",
]
CHECK = ["==> incoming commits", "abc1234 a change"]

# Worst realistic values: the repo's longest tool name and theme slug, CalVer
# and Go pseudo-version pins, drift, every source, 60 tools, a 200+ char doctor
# line (real ones reach 213), long commit subjects, a light active theme.
GROUPS = ["core", "git", "files", "containers", "system", "media", "dev"]
WORST_TOOLS = [
    tool("editorconfig-checker", "dev", "mise", True, True, "2026.10.11", "2026.9.30"),
    tool("kubectl-neat", "containers", "mise", True, True, "0.0.0-20261011120000-abc1234def56"),
    tool("jq", "core", "mise", True, False, "1.8.2"),
    tool("age-keygen", "files", "bundled", True, True),
    tool("mise", "core", "bootstrap", True, True),
    tool("lazydocker", "containers", "mise", False, False, "0.24.2"),
] + [
    tool(
        f"tool-{i:02d}",
        GROUPS[i % len(GROUPS)],
        ["mise", "native", "mise"][i % 3],
        i % 4 != 0,
        i % 5 != 0,
        f"{i}.{i % 7}.{i % 3}" if i % 3 != 1 else None,
        f"{i}.{i % 7}.{i % 3}" if i % 3 != 1 and i % 5 != 0 else None,
    )
    for i in range(1, 55)
]
HOME = "/Users/aleksandra.wisniewska-kowalczyk"
WORST_DOCTOR = [
    "OK    user-local bin dir on PATH",
    "OK    mise 2026.10.11 (pinned bootstrap, first on PATH)",
    "WARN  fzf also installed at /opt/homebrew/bin/fzf (shadowed); remove with: brew uninstall fzf",
    "FAIL  zellij: selected but not installed; run `dotfiles update` (or `mise install --locked`); expected "
    f"{HOME}/.local/share/mise/installs/aqua-zellij-org-zellij/0.44.3/bin/zellij",
    f"      {HOME}/.local/share/mise/installs/aqua-zellij-org-zellij is empty",
    "WARN  signing: ~/.ssh/id_ed25519.pub is not registered on GitHub as a signing key; run: "
    "gh ssh-key add ~/.ssh/id_ed25519.pub --type signing",
    *[f"OK    tool-{i:02d} {i}.0.0" for i in range(1, 40)],
    "doctor: 1 failure(s), 2 warning(s)",
]
SUBJECT = "feat(tui): keep the tools table summary on screen when the terminal is short and the catalog long"
WORST_CHECK = [
    "==> git fetch",
    "==> incoming commits",
    *[f"{i:07x} {SUBJECT}" for i in range(1, 9)],
    "==> chezmoi diff",
    "diff --git a/.config/ghostty/config b/.config/ghostty/config",
    "-background-opacity = 0.8",
    "+background-opacity = 0.66",
    "==> pending tool installs",
    "  jq 1.8.2 (not installed)",
    "  editorconfig-checker 2026.10.11 (installed: 2026.9.30)",
]
WORST_THEMES = [
    {"slug": s, "colors": LIGHT if "light" in s else PAL}
    for s in [
        "a",
        "gruvbox-material-light-medium",
        "iglass-light",
        "penumbra-dark-contrast-plus-plus",
        "penumbra-light-contrast-plus-plus",
        *[f"theme-{i:03d}" for i in range(1, 324)],
    ]
]

FILES = [
    {"path": ".config/ghostty/config", "local": True, "pending": True, "template": True},
    {"path": ".gitconfig.local", "local": True, "pending": False, "template": False},
    {"path": ".config/nvim/init.lua", "local": False, "pending": True, "template": False},
]
WORST_FILES = [
    {"path": "Library/Application Support/Code/User/settings.json", "local": True, "pending": True, "template": False},
    {"path": ".config/nvim/lua/config/keymaps.lua", "local": True, "pending": True, "template": False},
    *[
        {
            "path": f".config/some/deeply/nested/app-{i:02d}/config.toml",
            "local": False,
            "pending": True,
            "template": i % 3 == 0,
        }
        for i in range(1, 37)
    ],
]
MACHINE = {
    "path": "/Users/aleksandra.wisniewska-kowalczyk/workspace/dotfiles/ansible/local.yml",
    "exists": True,
    "values": {
        "git_name": "Aleksandra Wiśniewska-Kowalczyk",
        "git_email": "aleksandra.wisniewska-kowalczyk@northwind-industries-holdings.example.com",
        "personal_git_name": None,
        "personal_git_email": "12345678+awk@users.noreply.github.com",
        "personal_git_dirs": ["~/workspace/dotfiles/", "~/personal/"],
        "signing_key": "~/.ssh/id_ed25519.pub",
        "allow_sudo": True,
        "shared_home": None,
        "tool_groups": ["git", "dev"],
        "tools_add": ["lazydocker"],
        "tools_remove": None,
    },
    "signing": {"key": "~/.ssh/id_ed25519.pub", "exists": False},
}
DIFF = [
    "diff --git a/x b/x",
    "@@ -1,3 +1,3 @@",
    " font-size = 14",
    "-background-opacity = 0.9",
    "+background-opacity = 0.66",
]

if sub and sub == os.environ.get("STUB_BIG"):
    print("x" * 200_000, end="\r")
if args == ["files", "--json"]:
    print(json.dumps(WORST_FILES if worst else FILES))
elif args[:2] == ["files", "diff"]:
    print("\n".join(DIFF))
elif args == ["machine", "--json"]:
    print(json.dumps(MACHINE))
elif args == ["list", "--json"]:
    print(os.environ.get("STUB_LIST") or json.dumps(WORST_TOOLS if worst else TOOLS))
elif args == ["look", "--json"]:
    current = os.environ.get("STUB_THEME", "penumbra-light-contrast-plus-plus" if worst else "dark-one")
    levels = ["clear", "frosted", "tinted", "solid", "default"] if worst else ["clear", "frosted", "solid", "default"]
    look = {
        "theme": current,
        "glass": "frosted" if worst else None,
        "levels": levels,
        "themes": WORST_THEMES if worst else THEMES,
    }
    print(json.dumps(look))
elif sub == "doctor":
    print("\n".join(WORST_DOCTOR if worst else DOCTOR))
    sys.exit(1)
elif args == ["update", "--check"]:
    print("\n".join(WORST_CHECK if worst else CHECK))
else:
    print("applied " + " ".join(args))
