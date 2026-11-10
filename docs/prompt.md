# Prompt (Starship)

The prompt is [Starship](https://starship.rs), configured in
`home/dot_config/starship.toml.tmpl` (deployed to `~/.config/starship.toml`).
It is plain Starship config: change the layout in `format` or a segment in
its own table, using anything from the [Starship docs](https://starship.rs/config/),
then `chezmoi apply`. Open shells pick it up on their next prompt.

Only the colours are templated. `[palettes.base16]` maps names (`accent`,
`link`, `muted`, `err`, `red` … `magenta`) to the active theme, so a `style`
that uses those names follows `theme`. The roles behind `accent`, `accent2`,
`link` and the rest live in `home/.chezmoidata/design.toml`.

The cursor is Ghostty's: a blinking bar at the prompt (see the note in the
Ghostty config to change it).
