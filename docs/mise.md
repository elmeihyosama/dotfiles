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

## Activation model

- **Interactive shells:** dynamic activation via `mise activate zsh`
  (`home/dot_config/zsh/conf.d/49-mise.zsh`) — hooks into precmd so tool
  versions and env vars update live as you `cd` between projects.
- **Non-interactive / child shells:** `~/.zshenv` prepends mise's shims dir
  to `PATH` instead, since the dynamic activation hook isn't loaded there.

## Coexistence with the ansible toolchain

The ansible-provisioned tools in `~/.local/bin` (atuin, starship, eza, bat,
ripgrep, fzf, lazygit, yazi, jq, yq, gh, and friends — see
`ansible/group_vars/all.yml`) are a fixed, versionless CLI toolchain
installed once per machine. mise doesn't touch or replace any of that — it
only manages **language/runtime versions** (node, python, ruby, go, …) that
vary per project. The two layers are independent: fixed CLI tools come from
ansible, per-project runtimes come from mise.

PATH precedence differs by shell type: interactive shells put `~/.local/bin`
ahead of mise's shims (see `conf.d/00-env.zsh.tmpl`), while non-interactive
shells — which source only `.zshenv` — put mise's shims first, so a tool
pinned via mise can take precedence over an ansible-provisioned binary of
the same name in non-interactive contexts.
