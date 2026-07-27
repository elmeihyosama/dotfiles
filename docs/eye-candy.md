# Eye-Candy Extras

Two base16-themed showpieces wired into the theme system.

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
no-sudo Linux** (`ubi_unavailable`) — install it manually there if wanted.

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
