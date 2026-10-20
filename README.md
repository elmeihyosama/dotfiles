# Dotfiles

[![Lint](https://github.com/elmeihyosama/dotfiles/actions/workflows/lint.yml/badge.svg)](https://github.com/elmeihyosama/dotfiles/actions/workflows/lint.yml)
[![Provision](https://github.com/elmeihyosama/dotfiles/actions/workflows/provision.yml/badge.svg)](https://github.com/elmeihyosama/dotfiles/actions/workflows/provision.yml)

A cross-platform (macOS and Linux) terminal environment — managed with
[chezmoi], provisioned with [Ansible], and themed with [base16] (300+ palettes,
switchable with one command; [Rosé Pine Moon] by default). It bootstraps a fresh
machine with a single command and works even without `sudo`.

## Quick start

```bash
curl -fsSL https://elmeihyosama.github.io/dotfiles/install.sh | sh
```

One command — clones to `~/workspace/dotfiles`, prompts for your details, and provisions. Served from the project's [landing page](https://elmeihyosama.github.io/dotfiles/).

It installs Ansible (a pinned [uv], then the pinned ansible-core, on every
OS), prompts once for `git_name`, `git_email`, and whether to use sudo, then
runs the playbook (toolchain, JetBrains Mono Nerd Font, shell plugins, login
shell) and applies the config with `chezmoi apply`. Answers are saved to a git-ignored
`ansible/local.yml`.

It's safe to re-run: an existing clone is fast-forwarded, your saved answers
are reused, and the playbook only changes what's drifted. Re-run the prompts
with `./install.sh --reconfigure`.

### Manual clone

```bash
git clone https://github.com/elmeihyosama/dotfiles ~/workspace/dotfiles
cd ~/workspace/dotfiles
./install.sh
```

## Supported platforms

| Platform | Install strategy |
| --- | --- |
| ![macOS][badge-macos] (Apple Silicon) | mise-pinned CLI tools; Homebrew for the few native ones |
| ![Debian][badge-debian] ![Ubuntu][badge-ubuntu] | mise-pinned CLI tools; apt for essentials + native ones |
| ![Arch Linux][badge-arch] | mise-pinned CLI tools; pacman for essentials + native ones |
| ![Fedora][badge-fedora] | mise-pinned CLI tools; dnf for essentials + native ones |
| ![Rocky Linux][badge-rocky] ![AlmaLinux][badge-alma] | mise-pinned CLI tools; dnf for essentials + native ones |
| ![Any Linux][badge-linux] | mise-pinned CLI tools, user-local — works without `sudo` |

CLI tools and their versions live in `home/.chezmoidata/tools.yaml`; mise
installs them from a checksum-verified lock (`--locked`). Everything else is
pinned too (mise itself, the lint toolchain, zsh plugins, the Nerd Font, CI
images): Renovate proposes the bumps in one weekly PR and
`scripts/relock.sh` refreshes the checksums. If a bot PR fails `lock`, run
`scripts/relock.sh` on its branch, commit, push. One-time setup: install the
Renovate GitHub App for this repo. Details: [docs/mise.md](docs/mise.md#pins-and-renovate).

Every distro × both paths (sudo-native and no-sudo) is provisioned for real in CI.
WSL is supported and treated as Linux. Supported CPUs: Apple Silicon on macOS,
x86_64 and arm64 on Linux. Intel Macs are not supported (the pinned tools are
locked for those three platforms only); the playbook stops with a message
saying so.

## Highlights

- **One-command bootstrap** on a new machine via `install.sh`.
- **Declarative everywhere** — Ansible provisions, chezmoi configures.
- **Centralised theming** — 300+ base16 palettes; switch the whole stack with the `theme` command.
- **No-sudo friendly** — user-local installs; works on locked-down machines.
- **Linted** — shell, Ansible, Lua, and config checked in CI + pre-commit.

## Layout

| Path | Purpose |
| --- | --- |
| `home/` | chezmoi source tree (`.chezmoiroot` → `home`) |
| `ansible/` | Provisioning: tools, GUI apps (macOS casks), fonts, plugins, then `chezmoi apply` |
| `.github/` | CI workflows + shared lint/provision scripts (used by CI and pre-commit) |
| `install.sh` | Fresh-machine entry point (clone + provision) |

## The stack

| Area | Tools |
| --- | --- |
| Shell | zsh with [sheldon] plugins (highlighting, autosuggestions, fzf-tab) |
| Terminal · Prompt · Multiplexer | Ghostty · Starship · zellij |
| Editor | Neovim ([LazyVim]) |
| Files & CLI | yazi, bat, ripgrep, fzf, navi, git-delta, lazygit |
| Claude Code | Themed statusline (cwd · git · model · context · usage + reset countdown / cost) · account profiles (`claude-profile work`, `claude-work`) |
| Theme | base16 — 300+ palettes, `theme` switcher (Rosé Pine Moon default) |

## How it works

- **Centralised theme and font** — defined in `home/.chezmoidata/`; change
  `theme` in `theme.toml` to restyle the whole stack.
- **Secrets stay out of the repo** — Git auth via SSH and the system keychain;
  machine-local secrets in a git-ignored `~/.config/zsh/local.zsh`; chezmoi
  manages only non-secret, per-machine data.
- **No-sudo and locked-down machines** — when sudo is unavailable, tools
  install user-local (`~/.local/bin`) and, since the login shell can't be
  changed, a `.bashrc` shim hands off to zsh. All driven by the auto-detected
  `allow_sudo`; no manual flag needed.
- **Safe to adopt** — on first run, any pre-existing config it would overwrite
  is backed up to `<path>.pre-dotfiles.bak`, so adopting on a machine you
  already use is recoverable.

## Day to day

`dotfiles <subcommand>` manages the repo and this machine. Exit codes: 0 ok,
1 an operation failed, 2 usage or validation error.

- `dotfiles list [--json]` — catalog tools, whether this machine selects them,
  and what is installed.
- `dotfiles add TOOL|GROUP... [--no-apply]` / `dotfiles remove ...` — select or
  deselect tools and groups, then apply (`--no-apply` only edits). They edit
  only `tool_groups`, `tools_add` and `tools_remove` in `ansible/local.yml`.
  Removed mise tools are uninstalled; native ones get the command to run.
- `dotfiles update [--check]` — refuses a dirty repo, then runs `git pull
  --ff-only`, the ansible playbook, `chezmoi apply`, `sheldon lock`, nvim plugin
  restore and `doctor`, stopping at the first failure. `--check` only fetches
  (no file changes) and reports incoming commits, chezmoi drift and missing
  tools.
- `dotfiles doctor` — read-only health check (also `doctor`).

On macOS, Raycast has *Dotfiles Update* and *Dotfiles Doctor* commands
([Raycast](docs/raycast.md)).

## Usage

- Apply changes: `chezmoi apply` — preview with `chezmoi diff`.
- Add an editor language: `:LazyExtras` in Neovim.
- Switch theme: run `theme` (fuzzy picker with live preview) or `theme <slug>`;
  toggle the themed wallpaper with `wallpaper`. cmux repaints running sessions
  immediately; new shells, Ghostty windows, zellij, and Neovim pick it up on
  restart. The repo default lives in `home/.chezmoidata/theme.toml`.
- Command cheatsheets: run `navi` to browse the custom keybindings and workflow
  commands (theme, sessionizer, forgit, …).
- Lint locally: `.github/scripts/lint.sh all`. `install.sh` also sets up a pre-commit hook
  that runs these checks on each commit. The lint tools are pinned in the repo's
  `mise.toml` (checksums in `mise.lock`): run `mise trust` once, then `mise install`
  in the repo to get them. Entering the repo with mise activated prompts for that
  trust until you grant it. Inside the repo directory the root `mise.toml`'s tools take precedence over any home installs (via mise activation/shims), and each new git worktree needs its own `mise trust`. `lua` linting also needs `luajit`, and `zsh` stays native.
- Fresh machine, `chezmoi apply` before `./install.sh`: the zellij `glow`
  layout's status bar needs the zjstatus plugin that ansible installs, so it
  shows a plugin error until you run `./install.sh` — use `zellij -l split`
  in the meantime.

## Docs

Deeper guides for the non-obvious pieces:

- [Theming](docs/themes.md) — the base16 pipeline, semantic design tokens, and the switcher.
- [mise](docs/mise.md) — per-project runtimes, environment, and tasks.
- [Eye-candy](docs/eye-candy.md) — wallpaper↔theme pairing and themed cava.
- [Clipboard & notifications](docs/clipboard-notify.md) — OSC escape sequences that work over SSH.

## License

Released under the [MIT License](LICENSE).

[chezmoi]: https://www.chezmoi.io/
[Ansible]: https://www.ansible.com/
[base16]: https://github.com/tinted-theming/home
[Rosé Pine Moon]: https://rosepinetheme.com/
[uv]: https://docs.astral.sh/uv/
[sheldon]: https://sheldon.cli.rs/
[LazyVim]: https://www.lazyvim.org/

[badge-macos]: https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white
[badge-debian]: https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white
[badge-ubuntu]: https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white
[badge-arch]: https://img.shields.io/badge/Arch_Linux-1793D1?logo=archlinux&logoColor=white
[badge-fedora]: https://img.shields.io/badge/Fedora-51A2DA?logo=fedora&logoColor=white
[badge-rocky]: https://img.shields.io/badge/Rocky_Linux-10B981?logo=rockylinux&logoColor=white
[badge-alma]: https://img.shields.io/badge/AlmaLinux-0B6938?logo=almalinux&logoColor=white
[badge-linux]: https://img.shields.io/badge/Any_Linux-FCC624?logo=linux&logoColor=black
