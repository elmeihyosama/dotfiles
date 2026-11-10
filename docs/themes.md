# Themes

The palettes are base16 schemes in `home/.chezmoidata/themes/<slug>.toml`
(a `[themes.<slug>]` table of `base00`–`base0F`); the repo ships the four
Catppuccin flavours: `catppuccin-mocha` (default), `catppuccin-macchiato`,
`catppuccin-frappe` and `catppuccin-latte` (light). Every themed config
(ghostty, starship, zellij, yazi, bat, lazygit, btop, fzf, git-delta, nvim,
vivid/LS_COLORS) renders from those 16 colours, so switching restyles
everything at once.

> **Note:** documentation lives here under `docs/`, not inside
> `home/.chezmoidata/themes/`. chezmoi parses *every* file in a `.chezmoidata`
> directory as data, so a `.md` file there is a fatal error.

## Switching

The active theme lives in one place: `theme = "<slug>"` in
`home/.chezmoidata/theme.toml`. Change it and run `chezmoi apply`, or run
`theme <slug>` (`theme` alone lists them), which edits that line, applies only
the themed files and reloads what it can live: every running nvim (over its
RPC socket, 2s limit each), Ghostty (SIGUSR2 to your own `ghostty` processes;
if that fails, press `⌘⇧,`, or `ctrl+shift+,` on Linux) and zellij (live
sessions reload `config.kdl` on change). **Running TUIs (btop, lazygit,
yazi)** need a restart.

## Adding a theme

Any base16 scheme from [tinted-theming/schemes](https://github.com/tinted-theming/schemes):

```sh
sh scripts/base16-to-theme.sh path/to/scheme.yaml   # writes themes/<slug>.toml
sh scripts/gen-on-colors.sh                          # regenerates on_colors.toml
```

`on_colors.toml` holds, per theme, a readable text colour for each accent slot
(base00 or base05, whichever contrasts more), for chips drawn on an accent.

## Design roles

Chrome (the prompt, tab pills, borders) uses semantic roles from
`home/.chezmoidata/design.toml` (`accent`, `accent2`, `link`, `ok`, `warn`,
`err`, `rail`), each mapped to a base16 slot; content colouring (syntax, diffs,
file types) uses the raw slots.
