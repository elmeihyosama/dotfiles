# Clipboard & Notifications

Both features work over SSH: they write terminal escape sequences that ghostty
forwards to your local Mac.

## Copying to the clipboard

- **Mouse selection** copies automatically (**copy-on-select** is on): release a
  selection and it's on the clipboard — no ⌘C. Works in a bare ghostty pane and
  inside zellij (zellij routes it via OSC 52, so it works over SSH too). ⌘V
  pastes as usual. To turn it off: `copy_on_select false` in
  `~/.config/zellij/config.kdl` and `copy-on-select = false` in
  `~/.config/ghostty/config`.
- **`clip`** copies command *output* (no selecting needed) to your local
  clipboard, including from the SSH work box:

  ```
  pwd | clip
  git rev-parse HEAD | clip
  clip < build.log
  some-command | clip
  clip foo bar          # copies the arguments
  ```

  Locally it uses the native clipboard tool (`pbcopy`, or `wl-copy`/`xclip` on
  Linux); over SSH (or with no native tool) it emits OSC 52. On Linux without a
  clipboard tool, local copy still works via OSC 52 inside ghostty.
- **nvim**: over SSH, yanks to `+`/`*` go to the local clipboard via OSC 52
  automatically; local nvim uses the native provider. Pasting *in* over SSH is
  intentionally not wired (ghostty prompts on clipboard reads).

## Completion notifications

When a foreground command runs longer than `NOTIFY_THRESHOLD` seconds
(default 30), you get a desktop notification (delivered by ghostty, over SSH
included) plus a bell, showing the command, how long it took, and ✓/✗.

Interactive/expected-long commands are skipped via `NOTIFY_EXCLUDE`. The shipped
default list is:

```zsh
NOTIFY_EXCLUDE=(ssh nvim vim less man watch top htop btop tig lazygit lazydocker fzf yazi ff sz)
```

To customize, reassign the array in `~/.config/zsh/local.zsh`; note that
reassignment **replaces** the defaults, so include the commands you want to skip:

```zsh
NOTIFY_THRESHOLD=60
# Custom list — include defaults you want to keep, plus your own commands
NOTIFY_EXCLUDE=(ssh nvim vim less man watch top htop btop tig lazygit lazydocker fzf yazi ff sz my-repl)
```

To effectively disable, set `NOTIFY_THRESHOLD=999999`.

### macOS: grant the terminal notification permission

macOS authorizes notifications **per app**, so each terminal that forwards these
escapes must be allowed separately: **System Settings → Notifications → <your
terminal> → Allow Notifications**. If a long command doesn't banner, this is
almost always why — grant the permission (and check Focus/Do Not Disturb is off).
Note cmux and a standalone Ghostty.app are *different apps* here, so enabling one
does not enable the other.
