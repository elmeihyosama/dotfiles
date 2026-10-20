# mise

[mise](https://mise.jdx.dev/) is a per-project runtime manager: one config
file drives tool versions, environment variables, and task commands for a
project, and mise activates/deactivates all three automatically as you `cd`
in and out.

## Global config

`home/dot_config/mise/config.toml.tmpl` → `~/.config/mise/config.toml` ships
**no global tool pins** — versions come from each project's own `mise.toml`.
It only sets:

```toml
[settings]
status.show_tools = true
status.show_env = true
```

`status.show_tools`/`status.show_env` print a one-line summary of the tools
and env vars a directory's config loads whenever you `cd` into it — nice
feedback, no side effects. (Verified against the installed mise version,
`2026.7.14`, via `mise settings --all --toml`; these render into the
`[status]` table with keys `show_tools`/`show_env`.) Nothing here changes
mise's default trust behavior or idiomatic-version-file handling (e.g.
`.nvmrc`, `.python-version`) — those stay stock.

Add your own global pins with `mise use -g <tool>@<version>` (e.g.
`mise use -g node@lts`) — that writes to the same file.

## Per-project workflow

Each project gets its own `mise.toml` at its root:

```toml
[tools]
node = "22"
python = "3.12"

[env]
NODE_ENV = "development"

[tasks.dev]
run = "npm run dev"
```

- **`[tools]`** — pinned runtime versions for that project.
- **`[env]`** — environment variables loaded only while you're in that
  project's directory tree.
- **`[tasks]`** — named commands, run with `mise run <task>` (or `mise <task>`
  as shorthand). `mise tasks` lists everything defined.

### Secrets

Never put secrets in `mise.toml` (it's committed). Put them in a sibling
`mise.local.toml` instead — mise merges it in automatically, and it should be
gitignored per-project (add `mise.local.toml` to that project's
`.gitignore`).

### First use in a project

1. `mise trust` — one-time per project; mise refuses to load a project config it hasn't been told to trust, so a `cd` into an untrusted repo can't silently execute arbitrary tool/env/task config.
2. `mise install` — installs the versions pinned in `[tools]`.
3. `mise use <tool>@<version>` — pin/add a tool to the project config (add `-g` to write to the global config instead).
4. `mise run <task>` (or `mise <task>`) — run a defined task.
5. `mise tasks` — list available tasks.
6. `mise watch <task>` — rerun a task on file changes. Delegates to `watchexec`, which the ansible toolchain provisions, so this works out of the box.

## Activation model

- **Interactive shells:** dynamic activation via `mise activate zsh`
  (`home/dot_config/zsh/conf.d/49-mise.zsh`) — hooks into precmd so tool
  versions and env vars update live as you `cd` between projects.
- **Non-interactive / child shells:** `~/.zshenv` prepends mise's shims dir
  to `PATH` instead, since the dynamic activation hook isn't loaded there.

## The dotfiles CLI toolchain (also mise)

The CLI tools (atuin, starship, eza, bat, ripgrep, fzf, lazygit, yazi, jq,
yq, gh, and friends) are listed with exact versions in
`home/.chezmoidata/tools.yaml`. chezmoi renders the selected ones into
`~/.config/mise-dotfiles/config.toml` with the checksum lock `mise.lock`
beside it; mise reads that dir as its lowest-precedence "system" scope
(`MISE_SYSTEM_CONFIG_DIR`, exported in `.zshenv`, the bash rc files and the
Ansible environment). The playbook installs exactly those pins with
`MISE_GLOBAL_CONFIG_FILE=/nonexistent/mise-user.toml mise -C / install --locked`.
Your own `mise use -g` (writes `~/.config/mise/config.toml`) and project
`mise.toml` files outrank the dotfiles pins and keep working.

PATH precedence: mise wins over `~/.local/bin` and Homebrew in every shell
except the login, non-interactive case below.
`.zshenv` moves the shims dir to the front (non-interactive shells), and
`conf.d/00-env.zsh.tmpl` puts it back in front after prepending
`~/.local/bin`; interactive shells then run `mise activate`, which puts the
pinned install dirs first (`tests/path-precedence.test.sh`). `mise activate`
is cached in `$ZSH_CACHE_DIR/mise/activate.zsh` (about 12 ms saved per shell)
without the PATH snapshot that its raw output embeds, so every shell keeps
its own PATH entries (`tests/mise-activate-cache.test.sh`).

### Known gap: `zsh -lc` (login, non-interactive)

A login shell reads `~/.zprofile` after `.zshenv`, and nothing interactive
runs afterwards to put the shims back in front. Two things reorder PATH
there:

- Homebrew's installer tells you to add `eval "$(/opt/homebrew/bin/brew shellenv)"`
  to `~/.zprofile`. It prepends `/opt/homebrew/bin`, so a Homebrew copy of a
  pinned tool (an old `brew install fzf`) wins over mise's.
- On macOS, `/etc/zprofile` runs `path_helper`, which moves the system dirs
  (`/usr/local/bin`, `/usr/bin`, ...) ahead of everything else, including
  macOS's own `/usr/bin/jq`.

This affects `zsh -lc '...'` (some IDE task runners and launchers, `ssh` to a
host whose login shell is zsh with a command). Interactive shells, login or
not, are fixed by 00-env and `mise activate`. The dotfiles do not manage
`~/.zprofile` (it belongs to you and to installers that edit it). The fix is
one line at the end of `~/.zprofile`, after the `brew shellenv` line:

```zsh
path=("${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims" ${path:#${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims})
```

Use the same shims dir `.zshenv` uses: on a `shared_home` host that is
`$HOME/.local/share-$(uname -m)/mise/shims` instead.

Do not just delete the `brew shellenv` line: the dotfiles do not put
Homebrew on PATH themselves, so `brew` and its formulae would disappear from
every shell started from a login shell.

## Checking a machine: `doctor` and assert-tools

`doctor` (`scripts/doctor.sh`) runs `.github/scripts/assert-tools.sh`, the same
check CI runs after provisioning. For each mise tool it requires
`mise which --version <bin>` to equal the tools.yaml version, resolved with
`mise -C /`, `MISE_SYSTEM_CONFIG_DIR=~/.config/mise-dotfiles` and the global
config masked, so neither a project `mise.toml` (the repo's lint toolchain
included) nor `mise use -g` answers for a home tool. `command -v <bin>` must
then point inside mise's data dir. A non-mise copy further back on PATH is a
WARN with a removal hint (`brew uninstall X`, `sudo apt remove X`, ...); one
ahead of mise's is a FAIL. doctor also FAILs when the `mise` binary is not
the `mise_version` pinned in `ansible/group_vars/all.yml`.

## Pins and Renovate

Everything the dotfiles install is pinned to an exact version, and every
download is checked against a checksum:

| Pin | Lives in | Checksum |
| --- | --- | --- |
| Home CLI tools | `home/.chezmoidata/tools.yaml` | `home/dot_config/mise-dotfiles/mise.lock` |
| Repo lint toolchain | `mise.toml` | `mise.lock`, plus `.mise/locks/pipx-*/<ver>/uv.lock` |
| mise itself (bootstrap) | `mise_version` in `ansible/group_vars/all.yml` | `mise_sha256` beside it |
| CI's mise binary | `version:` in `.github/actions/setup-lint/action.yml` and the macOS job in `.github/workflows/provision.yml` | the `sha256:` input below it |
| uv, ansible-core, pre-commit (install.sh) | `ansible/group_vars/all.yml` | the repo `mise.lock` (same versions, `tests/python-pins.test.sh`) |
| JetBrainsMono Nerd Font | `nerd_font_version` in `ansible/group_vars/all.yml` | `checksum:` in `ansible/tasks/fonts.yml` |
| zsh plugins | `rev = "<commit>"` / `tag = "X"` in `home/dot_config/sheldon/plugins.toml` | the commit itself |
| CI container images | `image: <name>:<tag>@sha256:<digest>` in `.github/workflows/` | the digest |
| zjstatus | `zjstatus_by_zellij_minor` in `ansible/group_vars/all.yml` | per-entry `sha256` |

`scripts/relock.sh` is the one command that refreshes every checksum from
the versions above: `mise_sha256`, CI's mise `sha256:` inputs, both
`mise.lock` files (dropping `.mise/locks` uv.lock dirs the repo lock no
longer references), and the nerd font zip's sha256 (from the release's
`SHA-256.txt`). It is idempotent and prints what changed. To bump by hand,
edit the version, run it, commit.

[Renovate](https://docs.renovatebot.com/) (`renovate.json`) proposes the
version bumps, before 6am on Mondays, all in one "pins" PR so equal pins
across files move together:

- the `mise` manager reads the repo `mise.toml`;
- regex `customManagers` cover the tools.yaml entries (`aqua:`/`github:`
  backends via GitHub releases, plus its bootstrap `mise:` entry), the
  group_vars pins (`mise_version`, `uv_version`, `nerd_font_version` via
  GitHub releases; `ansible_core_version`, `pre_commit_version` via PyPI),
  CI's mise `version:` inputs, the workflow container images (tag and
  digest, provision.yml and bootstrap.yml together), and the sheldon pins;
- sheldon `rev` pins use the git-refs datasource with no branch, so they
  follow each plugin's **default branch** (its `HEAD`): a bump is "the
  latest commit there". forgit is pinned by release tag (`github-tags`).
- GitHub Actions stay with Dependabot (`.github/dependabot.yml`).
- `zjstatus_by_zellij_minor` stays manual: each entry must match a zellij
  minor's `zellij-tile` ABI (see the comment in group_vars).
- A container image's trailing `# <tag>` comment is not part of the match:
  fix it by hand when Renovate changes a tag (digest-only bumps keep it right).

`tests/renovate.test.sh` runs every customManager regex against the real
files and checks the match counts and captured versions, so a regex that
silently stops matching fails CI. It also runs the official
`renovate-config-validator` when `npx` and Node 24+ are available.

### A bot PR failed `lock`

Expected: Renovate edits versions but cannot compute checksums or locks, so
a tool, mise or nerd-font bump fails the `lock` check (or the mise sha256 /
playbook checks) until the checksums catch up. Check out the PR branch, then:

```sh
scripts/relock.sh
git add -A && git commit -m "relock"   # -A: picks up new .mise/locks/pipx-*/<ver>/ dirs
git push
```

### One-time setup

Install the [Renovate GitHub App](https://github.com/apps/renovate) for this
repo (GitHub, Settings, Integrations, or the app page: "Configure", then
select this repository). Renovate then opens its onboarding check against
the committed `renovate.json` and starts proposing bumps on the schedule.
