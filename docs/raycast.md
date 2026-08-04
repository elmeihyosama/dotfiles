# Raycast

What the repo manages, and what it deliberately can't.

## Managed: script commands

`home/dot_config/raycast/scripts/` → `~/.config/raycast/scripts` (macOS only)
ships [script commands] that tie Raycast into this stack:

- **Switch Theme** — `theme <slug>` with the slug as a Raycast argument.
- **Toggle Wallpaper** — the `wallpaper toggle` kill-switch.
- **Dotfiles Doctor** — `doctor` with full output in the Raycast window.

**One-time step per machine:** Raycast → Settings → Extensions → **Add Script
Directory** → pick `~/.config/raycast/scripts`. Raycast watches the directory
afterwards, so new/edited commands appear on the next `chezmoi apply` with no
further setup.

The commands run through `zsh -ic` so the repo's shell functions (`theme`,
`wallpaper`, `doctor`) are available.

## Managed elsewhere

- The app itself installs via the cask task (`ansible/tasks/casks.yml`).

## Deliberately not managed

- **Settings, hotkey, extensions**: Raycast keeps these in an internal store
  (not the `com.raycast.macos` defaults domain) and its export format is
  encrypted by design. Use Raycast's built-in Cloud Sync or
  Settings → Advanced → Export for backup — a dotfiles repo can't own this.
- `~/.config/raycast/{extensions,ai}` — Raycast's own runtime state.

[script commands]: https://github.com/raycast/script-commands
