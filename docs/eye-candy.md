# Eye-Candy Extras

Base16-themed showpieces wired into the theme system.

## Wallpaper ↔ theme pairing

Switching the base16 theme also sets a matching **ghostty terminal background
image**. The mapping and look live in `home/.chezmoidata/wallpaper.toml`:

- `[wallpaper]` — `opacity` (default `0.15`, a subtle texture), `fit`
  (`cover`), `position` (`center`). Tune these to taste.
- `[wallpaper.map]` — `theme-slug = "file.ext"` pairs. Files live in
  `~/.config/wallpapers/`. **Themes not listed here show no image** (the solid
  base00 background). Add a line to pair another theme; unassigned wallpapers
  include `nord-outer-space`, `rp-noise-line`, `eat-sleep-code`, `i-am-root`.

Switching a theme (`theme <slug>` or the fzf picker) re-renders the ghostty
config and updates the wallpaper automatically — no separate step.

### Turning it off

`wallpaper off` (or `wallpaper toggle`) disables the background image without
changing your theme; `wallpaper on` restores it. The on/off state is stored
per-machine in `~/.config/chezmoi/chezmoi.toml [data] wallpaper_mode`, so it
never shows up as a git diff. `wallpaper` with no argument toggles.

## Glass (translucency)

`glass <level>` sets the Ghostty background opacity and blur. Levels live in
`home/.chezmoidata/glass.toml`:

| Level | Opacity | Blur |
|---|---|---|
| `clear` | 0.50 | `macos-glass-clear` |
| `frosted` | 0.66 | `macos-glass-regular` |
| `tinted` | 0.82 | `macos-glass-regular` |
| `solid` | 1.0 | off |
| `default` | 0.8 | `20` (the original look) |

`glass off` is an alias for `default`; unset also means `default`. `glass` with
no argument opens an fzf picker. The level is stored per-machine in
`~/.config/chezmoi/chezmoi.toml [data] glass`, so it never shows up as a git
diff. The `macos-glass-*` blur needs macOS 26+; older macOS and Linux get the
plain blur (`20`).

**Readability:** `clear` is very see-through; text over busy windows is hard to
read. A wallpaper (`wallpaper on`) shows through the same translucency, so
prefer `tinted` or `solid` with one.

## Prompt (Starship) and cursor

The prompt's layout and colours are options, listed with their choices in
`home/.chezmoidata/prompt.toml`. The defaults are the prompt as it always was:
lean (coloured text), two lines joined by a `╭─`/`╰─` frame, duration and time
on the right, `❯`.

| Option | Choices (default first) |
|---|---|
| `style` | `lean` (coloured text), `rainbow` (coloured blocks) |
| `separator` | `round`, `angled`, `slanted`, `flat` — the blocks' ends (rainbow) |
| `lines` | `two`, `one` |
| `frame` | `on`, `off` (two lines) |
| `layout` | `split` (duration and time on the right), `left` |
| `fill` | `space`, `dots`, `line`, `dashed` — the gap before the right side (two lines, split) |
| `char` | `chevron` ❯, `arrow` ➜, `lambda` λ, `dollar` $, `triangle` ▶ |
| `time` | `24h`, `12h`, `off` |
| `icons` | `nerd`, `plain` (text labels, for fonts without Nerd Font glyphs) |
| `langs` | `on`, `off` — Node, Python, Rust and Go versions |
| `spacing` | `sparse` (a blank line before each prompt), `compact` |
| `dir_color`, `git_color`, `char_color`, `frame_color` | a theme colour: `accent`, `accent2`, `link`, `ok`, `warn`, `err`, `rail`, `muted`, `text`, `red` … `magenta` |
| `cursor` | `bar`, `block`, `underline` — Ghostty's cursor shape |
| `blink` | `on`, `off` |

The TUI's **Prompt** tab shows the real prompt (Starship's own output) for
the highlighted choice before anything changes; `enter` applies. From a shell:

```sh
dotfiles prompt lines=one char=lambda   # several at once; each is checked first
dotfiles prompt reset                    # every option back to its default
```

Choices are stored per machine as `prompt_<option>` in
`~/.config/chezmoi/chezmoi.toml [data]` (no git diff); an unknown value reads
as the default. Applying touches only `starship.toml` and the Ghostty config.
Starship reads its config at every prompt, so open shells change on their next
one. The colours follow the theme. A cursor other than `bar` turns off Ghostty
shell integration's own prompt cursor, which would otherwise make it a bar at
the prompt.

## cava — audio visualizer

`cava` renders an audio spectrum whose gradient bars are drawn from the active
base16 palette (`home/dot_config/cava/config.tmpl`), so it re-themes with the
switcher. Config re-renders on `chezmoi apply`; a **running** cava needs a
restart (or its `r` reload key) to repaint.

By default cava visualizes the **default input device (the mic)** out of the
box, with the input method auto-selected per-OS: CoreAudio on macOS, PulseAudio
on Linux. No extra driver installation needed.

Provisioning: installed via Homebrew on macOS and the native package manager on
sudo-capable Linux. Upstream ships source-only releases, so cava is **skipped on
no-sudo Linux** (`native_only` in tools.yaml) — install it manually there if wanted.

### Visualizing system audio (optional, not automated)

To make cava react to *playback* instead of the mic, route system audio through
a virtual loopback device:

1. Install [BlackHole](https://github.com/ExistentialAudio/BlackHole)
  (`brew install blackhole-2ch`) — this is an audio driver (admin install).
2. In **Audio MIDI Setup**, create a Multi-Output Device combining your
  speakers + BlackHole, and set it as the system output.
3. Point cava at BlackHole: in `~/.config/cava/config` set `[input] source =
  BlackHole` (keep `method = coreaudio` on macOS).

This is a manual, machine-specific setup and is intentionally not part of the
dotfiles.
