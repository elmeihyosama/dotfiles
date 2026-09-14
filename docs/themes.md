# Themes

This repo ships a vendored snapshot of every [base16](https://github.com/tinted-theming/home)
scheme from [`tinted-theming/schemes`](https://github.com/tinted-theming/schemes)
(~326 palettes). Each lives in `home/.chezmoidata/themes/<slug>.toml` as a
`[themes.<slug>]` table of `base00`–`base0F`. Every themed app config
(ghostty, alacritty, warp, starship, zellij, yazi, bat, lazygit, lazydocker,
btop, fzf, git-delta, gh-dash, cava, nvim, vivid/LS_COLORS) renders from those
16 colors, so switching the active theme restyles everything at once.

> **Note:** documentation lives here under `docs/`, not inside
> `home/.chezmoidata/themes/`. chezmoi parses *every* file in a `.chezmoidata`
> directory as data, so a `.md` file there is a fatal error.

## Choosing the active theme

- **Repo default:** `home/.chezmoidata/theme.toml` → `theme = "<slug>"`.
- **Per-machine override (no git diff):** `~/.config/chezmoi/chezmoi.toml`
  `[data] theme = "<slug>"`. This wins over the repo default, so each machine
  can run its own theme without touching the repo.

## Switching

- **Interactive:** run `theme` (fzf picker over all schemes) or `theme <slug>`.
- **Manual:** set the slug in one of the places above, then `chezmoi apply`.

New shells and new ghostty windows pick the theme up automatically; existing
**ghostty windows, zellij sessions, nvim, and running TUIs (btop, lazydocker,
lazygit, yazi)** need a reload/restart.

### cmux

[cmux] reads `~/.config/ghostty/config` directly, so it follows the switcher
with no extra config; the `theme` command runs `cmux reload-config` to repaint
running sessions live. Do **not** run `cmux themes set <preset>` — that writes a
cmux override that shadows the Ghostty config with a vendored preset, breaking
the base16 sync (`cmux themes clear` restores it).

[cmux]: https://cmux.com/

### Windows-side terminals on WSL

Alacritty and Warp can both run as *Windows* apps against a WSL distro, and
then they read their config from `%APPDATA%`/`%LOCALAPPDATA%` — outside
chezmoi's tree, which is `$HOME` on the Linux side. Two `run_onchange` scripts
bridge the gap after every apply, so `theme` repaints them like everything
else:

| script | what it copies across |
| --- | --- |
| `.chezmoiscripts/run_onchange_after_60-alacritty-wsl.sh` | `~/.config/alacritty/colors.toml` → `%APPDATA%\alacritty\` |
| `.chezmoiscripts/run_onchange_after_61-warp-wsl.sh` | `~/.local/share/warp-terminal/themes/base16-active.yaml` → `%APPDATA%\warp\Warp\data\themes\` |

Both no-op off WSL and when the Windows-side app isn't installed. The Warp
script also rewrites two keys in `%LOCALAPPDATA%\warp\Warp\config\settings.toml`:
`[appearance.themes].theme`, pointing Warp at the copied palette, and
`[session].new_session_shell_override`, so new Warp sessions open
`$WSL_DISTRO_NAME` instead of PowerShell. Warp watches that file and
hot-reloads, so neither needs a restart — but tabs already open keep the shell
they started with.

Two Warp gotchas worth knowing:

- **The bundled schema lies about the shell key.** `resources/settings_schema.json`
  in the Warp install documents the WSL variant as `w_s_l`; Warp's own parser
  only accepts `wsl`, and rejects the rest of the file with a "settings file
  contains an error" banner if you use the documented spelling. The theme's
  `{ custom = { name, path } }` shape, from the same schema, *is* correct.
- **Cloud settings sync can outrank the file.** With `[account]
  is_settings_sync_enabled = true`, Warp reconciles the theme against your Warp
  account at launch and has been seen overwriting the file's theme with the
  cloud one. Switching themes with Warp *running* is safe (the file wins and is
  pushed up); a switch made while Warp is closed could get reverted on next
  launch. Set `is_settings_sync_enabled = false` if that ever bites.

## Recommended

rose-pine-moon · rose-pine · rose-pine-dawn · catppuccin-mocha ·
catppuccin-macchiato · gruvbox-dark-medium · nord · tomorrow-night · dracula ·
solarized-dark · solarized-light · everforest · kanagawa · onedark · ayu-mirage

(Any of the ~326 slugs in `home/.chezmoidata/themes/` is selectable — these are
just popular starting points.)

## Re-syncing / adding themes

The theme TOMLs are generated from upstream by `scripts/base16-to-theme.sh`.
To refresh the snapshot or pull in new schemes:

    git clone --depth 1 https://github.com/tinted-theming/schemes /tmp/schemes
    sh scripts/base16-to-theme.sh -d /tmp/schemes/base16

The converter is idempotent — re-running regenerates the files in place.

## Canonical mappings

- **ANSI (terminals):** 0=base00 1=base08 2=base0B 3=base0A 4=base0D 5=base0E
  6=base0C 7=base05 8=base03 9–14=repeat 1–6, 15=base07.
- **Design roles (UI chrome):** defined in `home/.chezmoidata/design.toml`;
  chrome templates must use roles, content colouring uses raw slots.

## Auditing

`scripts/theme-audit.sh` re-fetches tinted-theming/schemes, regenerates all
TOMLs, and reports DRIFT / COLLISION / LOWCONTRAST. Collisions are upstream
facts (e.g. rose-pine-moon's gold appears as both base09 and base0E) — the
role layer exists so chrome can route around them.
