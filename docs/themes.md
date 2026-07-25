# Themes

This repo ships a vendored snapshot of every [base16](https://github.com/tinted-theming/home)
scheme from [`tinted-theming/schemes`](https://github.com/tinted-theming/schemes)
(~326 palettes). Each lives in `home/.chezmoidata/themes/<slug>.toml` as a
`[themes.<slug>]` table of `base00`–`base0F`. Every themed app config
(ghostty, starship, zellij, yazi, lazygit, fzf, git-delta, nvim) renders from
those 16 colors, so switching the active theme restyles everything at once.

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
**ghostty windows, zellij sessions, and nvim** need a reload/restart.

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
