# Prompt (Starship) and cursor

The prompt's layout and colours are options, listed with their choices in
`home/.chezmoidata/prompt.toml`. The defaults are the prompt as it always was:
lean (coloured text), two lines joined by a `╭─`/`╰─` frame, duration and time
on the right, `❯`.

| Option | Choices (default first) |
|---|---|
| `style` | `lean` (coloured text), `rainbow` (coloured blocks), `bar` (one strip, segments split by thin dividers) |
| `separator` | `round`, `angled`, `slanted`, `flat` — the blocks' or the bar's ends, and the bar's dividers |
| `start` | `same` (as `separator`), `round`, `angled`, `slanted`, `flat` — the left end alone, e.g. `round` with `angled` ends for an arrow pointing right |
| `right_ends` | `same` (as on the left), `round`, `angled`, `slanted`, `flat` — the right side's (duration, clock) own shape |
| `bar_color` | `theme`, `surface`, `raised`, or any colour below — the bar (bar style). `theme` follows the active theme (`dotfiles theme …`): the directory on the directory colour, git on the branch colour, the rest a shade above the background (base02), each with its own join. Any other is one strip of that colour; on `surface`/`raised`/`muted` the text keeps each segment's colour, on a bright one it is dark |
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

Set them from a shell:

```sh
prompt_set lines=one char=lambda   # several at once; each is checked first
prompt_set reset                   # every option back to its default
```

Choices are stored per machine as `prompt_<option>` in
`~/.config/chezmoi/chezmoi.toml [data]` (no git diff); picking a default
removes the key, and an unknown value reads as the default. Applying touches
only `starship.toml`, the Ghostty config and `~/.config/zsh/cursor`; it runs
from the checkout chezmoi applies from (another checkout previews only). Open
shells change on their next prompt: Starship reads its config every time, and
so does the cursor hook. The colours follow the theme.

The cursor: Ghostty's shell integration draws a blinking bar at the prompt
(and a block in vi command mode). Any other choice turns that off
(`shell-integration-features = no-cursor`) and `conf.d/70-prompt.zsh` draws
the chosen shape instead, still a block in vi command mode; programs you run
get the same shape from Ghostty's `cursor-style`.
