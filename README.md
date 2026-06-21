# Dotfiles

A cross-platform (macOS and Linux) terminal environment — managed with
[chezmoi], provisioned with [Ansible], and themed with [Rosé Pine Moon]. It
bootstraps a fresh machine with a single command and works even without `sudo`.

**Supported:** macOS, Debian/Ubuntu, and Arch Linux, plus any Linux without
`sudo` (user-local installs). WSL is treated as Linux; native Windows is out of
scope.

## Highlights

- **One-command bootstrap** on a new machine via `install.sh`.
- **Declarative everywhere** — Ansible provisions, chezmoi configures.
- **Centralised theming** — restyle the entire stack from a single value.
- **No-sudo friendly** — user-local installs; works on locked-down machines.
- **Linted** — shell, Ansible, Lua, and config checked in CI + pre-commit.

## Layout

| Path | Purpose |
| --- | --- |
| `home/` | chezmoi source tree (`.chezmoiroot` → `home`) |
| `ansible/` | Provisioning: tools, fonts, plugins, then `chezmoi apply` |
| `ci/` | Shared lint script used by CI and pre-commit |
| `install.sh` | Fresh-machine entry point (clone + provision) |

## Quick start

One command — clones to `~/dotfiles`, prompts for your details, provisions:

```bash
sh -c "$(curl -fsSL https://gitlab.com/oelmeihy/dotfiles/-/raw/main/install.sh)"
```

It installs Ansible (Homebrew, apt/pacman, or [uv] on no-sudo hosts), prompts
once for `git_name`, `git_email`, and whether to use sudo, then runs the
playbook (toolchain, JetBrains Mono Nerd Font, shell plugins, login shell) and
applies the config with `chezmoi apply`. Answers are saved to a git-ignored
`ansible/local.yml`.

It's safe to re-run: an existing clone is fast-forwarded, your saved answers
are reused, and the playbook only changes what's drifted. Re-run the prompts
with `./install.sh --reconfigure`.

### Manual clone

```bash
git clone https://gitlab.com/oelmeihy/dotfiles ~/dotfiles
cd ~/dotfiles
./install.sh
```

## The stack

| Area | Tools |
| --- | --- |
| Shell | zsh with [sheldon] plugins (highlighting, autosuggestions, fzf-tab) |
| Terminal · Prompt · Multiplexer | Ghostty · Starship · zellij |
| Editor | Neovim ([LazyVim]) |
| Files & CLI | yazi, bat, ripgrep, fzf, navi, git-delta, lazygit |
| Theme | Rosé Pine Moon throughout |

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

## Usage

- Apply changes: `chezmoi apply` — preview with `chezmoi diff`.
- Add an editor language: `:LazyExtras` in Neovim.
- Switch theme: edit `theme` in `home/.chezmoidata/theme.toml`, then apply.
- Lint locally: `ci/lint.sh all`. `install.sh` also sets up a pre-commit hook
  that runs these checks on each commit.

## License

Released under the [MIT License](LICENSE).

[chezmoi]: https://www.chezmoi.io/
[Ansible]: https://www.ansible.com/
[Rosé Pine Moon]: https://rosepinetheme.com/
[uv]: https://docs.astral.sh/uv/
[sheldon]: https://sheldon.cli.rs/
[LazyVim]: https://www.lazyvim.org/
