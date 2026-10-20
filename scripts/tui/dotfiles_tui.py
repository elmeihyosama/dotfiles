#!/usr/bin/env -S uv run --quiet --locked --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["textual==8.2.8"]
# ///
"""dotfiles TUI: tools, health, update and look, on top of scripts/dotfiles.sh.

Every read and every change goes through the CLI (its `list --json` and
`look --json` contracts), so the TUI holds no logic the CLI lacks.
DOTFILES_CMD replaces the CLI command line (tests use a stub).
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shlex
import signal
import sys
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path
from typing import Any

from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.theme import Theme
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Input,
    Label,
    OptionList,
    RichLog,
    Static,
    TabbedContent,
    TabPane,
)
from textual.widgets.option_list import Option

REPO = Path(__file__).resolve().parents[2]
BASES = [f"base0{c}" for c in "0123456789ABCDEF"]
HEX = re.compile(r"#[0-9a-fA-F]{6}")


def cli() -> list[str]:
    """The dotfiles CLI command line."""
    if override := os.environ.get("DOTFILES_CMD"):
        return shlex.split(override)
    return ["sh", str(REPO / "scripts" / "dotfiles.sh")]


# Children get no terminal: a new session has no controlling tty, so chezmoi
# and git fail fast instead of prompting under the TUI. Lines can be long
# (progress bars, diffs): read chunks, not asyncio's 64 KiB-limited lines.
CHILD_ENV = {"NO_COLOR": "1", "GIT_TERMINAL_PROMPT": "0"}
LIVE: set[asyncio.subprocess.Process] = set()  # stopped on quit


async def spawn(args: list[str] | tuple[str, ...], *, merge: bool) -> asyncio.subprocess.Process:
    proc = await asyncio.create_subprocess_exec(
        *cli(),
        *args,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT if merge else asyncio.subprocess.PIPE,
        env={**os.environ, **CHILD_ENV},
        start_new_session=True,
    )
    LIVE.add(proc)
    return proc


async def stop(proc: asyncio.subprocess.Process) -> None:
    """Kill PROC's process group if it is still running (cancel, quit), then
    reap it so no zombie or open pipe outlives the command."""
    LIVE.discard(proc)
    if proc.returncode is None:
        with suppress(ProcessLookupError, PermissionError):
            os.killpg(proc.pid, signal.SIGTERM)
        with suppress(TimeoutError, ProcessLookupError):
            await asyncio.wait_for(proc.wait(), 5)


async def capture(*args: str) -> tuple[int, str, str]:
    """Run the CLI with ARGS; return (rc, stdout, stderr)."""
    try:
        proc = await spawn(args, merge=False)
    except OSError as e:
        return 127, "", f"cannot run the dotfiles CLI: {e}"
    try:
        out, err = await proc.communicate()
    finally:
        await stop(proc)
    return proc.returncode or 0, out.decode(errors="replace"), err.decode(errors="replace")


async def stream(args: list[str], line: Callable[[str], None]) -> int:
    """Run the CLI with ARGS, passing each stdout/stderr line to LINE."""
    try:
        proc = await spawn(args, merge=True)
    except OSError as e:
        line(f"FAIL  cannot run the dotfiles CLI: {e}")
        return 127
    assert proc.stdout is not None
    buf = b""
    try:
        while chunk := await proc.stdout.read(65536):
            *done, buf = re.split(rb"\r\n|\r|\n", buf + chunk)
            for raw in done:
                line(raw.decode(errors="replace"))
        if buf:
            line(buf.decode(errors="replace"))
        return await proc.wait()
    finally:
        await stop(proc)


def field(item: dict[str, Any], key: str) -> str:
    """ITEM[KEY] when it is a string, else "" (nulls, off-contract values)."""
    value = item.get(key)
    return value if isinstance(value, str) else ""


def tone(app: App[Any], spec: str) -> str:
    """SPEC with each $name (success, warning, error, primary, accent) as the
    active theme's colour: Rich styles don't know Textual's variables."""
    theme = app.current_theme
    return " ".join((getattr(theme, w[1:], None) or "") if w.startswith("$") else w for w in spec.split())


def styled(app: App[Any], line: str) -> Text:
    """A CLI output line, coloured by its doctor/update prefix."""
    for prefix, style in (
        ("OK", "$success"),
        ("WARN", "$warning"),
        ("FAIL", "$error"),
        ("==>", "bold $accent"),
        ("dotfiles:", "$warning"),
    ):
        if line.startswith(prefix):
            return Text(line, style=tone(app, style))
    return Text(line)


def base16_theme(colors: dict[str, str]) -> Theme:
    """A Textual theme from a base16 palette (dark unless base00 is light)."""
    bg = colors["base00"].lstrip("#")
    r, g, b = (int(bg[i : i + 2], 16) for i in (0, 2, 4))
    return Theme(
        name="dotfiles",
        primary=colors["base0D"],
        secondary=colors["base0E"],
        accent=colors["base0C"],
        warning=colors["base0A"],
        error=colors["base08"],
        success=colors["base0B"],
        foreground=colors["base05"],
        background=colors["base00"],
        surface=colors["base01"],
        panel=colors["base02"],
        dark=(0.299 * r + 0.587 * g + 0.114 * b) < 128,
    )


def swatch(slug: str, colors: dict[str, str]) -> Text:
    """A preview of a palette: the 16 colours and a code sample."""
    t = Text()
    t.append(f" {slug}\n\n", style="bold")
    for row in (BASES[:8], BASES[8:]):
        for k in row:
            t.append("      ", style=f"on {colors[k]}")
            t.append(" ")
        t.append("\n")
        for k in row:
            t.append(f"{k[4:]:^6} ", style="dim")
        t.append("\n\n")
    bg, fg = colors["base00"], colors["base05"]
    sample = [
        [("# switch the look", colors["base03"])],
        [
            ("def ", colors["base0E"]),
            ("apply", colors["base0D"]),
            ("(theme: ", fg),
            ("str", colors["base0A"]),
            ("):", fg),
        ],
        [
            ("    run(", fg),
            ('"chezmoi apply"', colors["base0B"]),
            (", retries=", fg),
            ("3", colors["base09"]),
            (")", fg),
        ],
        [("    ", fg), ("raise ", colors["base08"]), ("Done", colors["base0C"])],
    ]
    for parts in sample:
        width = 0
        for text, color in parts:
            t.append(text, style=f"{color} on {bg}")
            width += len(text)
        t.append(" " * max(0, 46 - width), style=f"on {bg}")
        t.append("\n")
    return t


class Confirm(ModalScreen[bool]):
    """Yes/no dialog."""

    BINDINGS = [Binding("y", "answer(True)", "yes"), Binding("n,escape", "answer(False)", "no")]

    def __init__(self, question: str) -> None:
        super().__init__()
        self.question = question

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Label(self.question)
            with Horizontal(classes="buttons"):
                yield Button("Yes (y)", variant="primary", id="yes")
                yield Button("No (n)", id="no")

    def action_answer(self, yes: bool) -> None:
        self.dismiss(yes)

    @on(Button.Pressed)
    def pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")


class Run(ModalScreen[int]):
    """Stream one or more CLI commands into a log; dismiss with the last rc."""

    BINDINGS = [Binding("escape,q", "close", "close")]

    def __init__(self, title: str, commands: list[list[str]]) -> None:
        super().__init__()
        self.title_text = title
        self.commands = commands
        self.rc: int | None = None

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog wide"):
            yield Label(self.title_text, classes="title")
            yield RichLog(id="run-log", wrap=True, min_width=20)
            yield Label("running…", id="run-status")

    def on_mount(self) -> None:
        self.go()

    @work(exclusive=True)
    async def go(self) -> None:
        log = self.query_one(RichLog)
        rc = 0
        for args in self.commands:
            log.write(Text(f"$ dotfiles {shlex.join(args)}", style="bold"))
            rc = await stream(args, lambda s: log.write(styled(self.app, s)))
            if rc:
                break
        self.rc = rc
        status = self.query_one("#run-status", Label)
        if rc:
            status.update(Text(f"failed (exit {rc}) — esc to close", style=tone(self.app, "$error")))
        else:
            status.update(Text("done — esc to close", style=tone(self.app, "$success")))

    def action_close(self) -> None:
        if self.rc is None:
            self.notify("still running", severity="warning")
            return
        self.dismiss(self.rc)


class ToolsPane(TabPane):
    """The tool catalog with selection and install state."""

    BINDINGS = [
        Binding("space", "toggle", "mark add/remove"),
        Binding("a", "apply", "apply marks"),
        Binding("r", "refresh", "refresh"),
        Binding("slash", "filter", "filter"),
    ]

    def __init__(self) -> None:
        super().__init__("Tools", id="tools")
        self.main = "#tool-table"  # focused when the tab opens, so its keys work
        self.tools: list[dict[str, Any]] = []
        self.pending: dict[str, str] = {}

    def compose(self) -> ComposeResult:
        yield Input(placeholder="filter tools (/)", id="tool-filter")
        yield DataTable(id="tool-table", cursor_type="row", zebra_stripes=True)
        yield Label("", id="tool-summary")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        for label, key in (
            ("", "mark"),
            ("tool", "name"),
            ("group", "group"),
            ("source", "source"),
            ("", "installed"),
            ("pinned", "pinned"),
            ("actual", "actual"),
        ):
            table.add_column(label, key=key)
        self.action_refresh()

    @work(exclusive=True, group="tools")
    async def action_refresh(self) -> None:
        table = self.query_one(DataTable)
        table.loading = True
        rc, out, err = await capture("list", "--json")
        table.loading = False
        try:
            if rc:
                raise ValueError(err.strip() or f"exit {rc}")
            tools = json.loads(out)
            if not isinstance(tools, list):
                raise ValueError("not a list")
        except (ValueError, json.JSONDecodeError) as e:
            self.tools = []
            self.render_rows()
            self.query_one("#tool-summary", Label).update(
                Text(f"dotfiles list failed: {e}", style=tone(self.app, "$error"))
            )
            return
        # off-contract items are dropped, not fatal
        self.tools = [t for t in tools if isinstance(t, dict) and isinstance(t.get("name"), str)]
        self.pending = {k: v for k, v in self.pending.items() if any(t["name"] == k for t in tools)}
        self.render_rows()

    def mark_cell(self, tool: dict[str, Any]) -> Text:
        match self.pending.get(tool["name"]):
            case "add":
                return Text("+", style=tone(self.app, "bold $success"))
            case "remove":
                return Text("−", style=tone(self.app, "bold $error"))
        return Text("✓", style=tone(self.app, "$primary")) if tool.get("selected") else Text("·", style="dim")

    def render_rows(self) -> None:
        table = self.query_one(DataTable)
        needle = self.query_one("#tool-filter", Input).value.strip().lower()
        cursor = table.cursor_row
        table.clear()
        shown = drift = missing = 0
        for t in self.tools:
            group, source = field(t, "group"), field(t, "source")
            hay = f"{t['name']} {group} {source}".lower()
            if needle and needle not in hay:
                continue
            shown += 1
            pinned, actual = field(t, "pinned"), field(t, "actual")
            drifted = bool(actual and pinned and actual != pinned)
            drift += drifted
            missing += bool(t.get("selected") and not t.get("installed"))
            table.add_row(
                self.mark_cell(t),
                t["name"],
                Text(group, style="dim"),
                source,
                Text("●", style=tone(self.app, "$success")) if t.get("installed") else Text("○", style="dim"),
                pinned,
                Text(actual, style=tone(self.app, "bold $warning") if drifted else ""),
                key=t["name"],
            )
        if shown:
            table.move_cursor(row=min(cursor, shown - 1))
        parts = [f"{shown}/{len(self.tools)} tools"]
        if missing:
            parts.append(f"{missing} selected but missing")
        if drift:
            parts.append(f"{drift} not at their pin")
        if self.pending:
            parts.append(f"{len(self.pending)} marked — a to apply")
        self.query_one("#tool-summary", Label).update(" · ".join(parts))

    @on(Input.Changed, "#tool-filter")
    def filtered(self) -> None:
        self.render_rows()

    @on(Input.Submitted, "#tool-filter")
    def filter_done(self) -> None:
        self.query_one(DataTable).focus()

    def action_filter(self) -> None:
        self.query_one("#tool-filter", Input).focus()

    def action_toggle(self) -> None:
        table = self.query_one(DataTable)
        if not table.row_count:
            return
        name = str(table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value)
        tool = next(t for t in self.tools if t["name"] == name)
        if name in self.pending:
            del self.pending[name]
        else:
            self.pending[name] = "remove" if tool.get("selected") else "add"
        row = table.cursor_row
        self.render_rows()
        table.move_cursor(row=min(row + 1, table.row_count - 1))

    def action_apply(self) -> None:
        if not self.pending:
            self.notify("nothing marked: space marks a tool to add or remove")
            return
        adds = sorted(n for n, v in self.pending.items() if v == "add")
        removes = sorted(n for n, v in self.pending.items() if v == "remove")
        commands = [["add", *adds]] if adds else []
        commands += [["remove", *removes]] if removes else []
        summary = "; ".join(shlex.join(c) for c in commands)

        def confirmed(yes: bool | None) -> None:
            if yes:
                self.app.push_screen(Run("Apply tool changes", commands), self.applied)

        self.app.push_screen(Confirm(f"Run: dotfiles {summary}?"), confirmed)

    def applied(self, rc: int | None) -> None:
        if rc == 0:
            self.pending.clear()
        self.action_refresh()


class HealthPane(TabPane):
    """`dotfiles doctor`, coloured, with counts."""

    BINDINGS = [Binding("r", "check", "re-run doctor")]

    def __init__(self) -> None:
        super().__init__("Health", id="health")
        self.main = "#health-log"  # focused when the tab opens, so its keys work
        self.ran = False

    def compose(self) -> ComposeResult:
        yield Label("", id="health-summary")
        yield RichLog(id="health-log", wrap=True, min_width=20)

    @work(exclusive=True, group="health")
    async def action_check(self) -> None:
        self.ran = True
        log = self.query_one(RichLog)
        summary = self.query_one("#health-summary", Label)
        log.clear()
        summary.update("running doctor…")
        counts = {"OK": 0, "WARN": 0, "FAIL": 0}

        def line(s: str) -> None:
            word = s.split(" ", 1)[0]
            if word in counts:
                counts[word] += 1
            log.write(styled(self.app, s))

        rc = await stream(["doctor"], line)
        text = Text()
        text.append(f"{counts['OK']} ok", style=tone(self.app, "$success"))
        text.append("  ")
        text.append(f"{counts['WARN']} warn", style=tone(self.app, "$warning") if counts["WARN"] else "dim")
        text.append("  ")
        text.append(f"{counts['FAIL']} fail", style=tone(self.app, "bold $error") if counts["FAIL"] else "dim")
        if rc and not counts["FAIL"]:
            text.append(f"  (doctor exited {rc})", style=tone(self.app, "$error"))
        summary.update(text)


class UpdatePane(TabPane):
    """`dotfiles update --check`, and `update` after a confirm."""

    BINDINGS = [Binding("c", "check", "check again"), Binding("u", "update", "update now")]

    def __init__(self) -> None:
        super().__init__("Update", id="update")
        self.main = "#update-log"  # focused when the tab opens, so its keys work
        self.ran = False

    def compose(self) -> ComposeResult:
        yield Label("what `dotfiles update` would change — u runs it", id="update-summary")
        yield RichLog(id="update-log", wrap=True, min_width=20)

    @work(exclusive=True, group="update")
    async def action_check(self) -> None:
        self.ran = True
        log = self.query_one(RichLog)
        log.clear()
        rc = await stream(["update", "--check"], lambda s: log.write(styled(self.app, s)))
        if rc:
            log.write(Text(f"update --check exited {rc}", style=tone(self.app, "$error")))

    def action_update(self) -> None:
        def confirmed(yes: bool | None) -> None:
            if yes:
                # a still-streaming check would race the pull (its process group is killed)
                self.app.workers.cancel_group(self, "update")
                self.app.push_screen(Run("dotfiles update", [["update"]]), lambda _rc: self.action_check())

        self.app.push_screen(Confirm("Pull the repo, run the playbook and chezmoi apply, then doctor?"), confirmed)


class LookPane(TabPane):
    """Theme and glass, with a live palette preview."""

    BINDINGS = [Binding("slash", "filter", "filter"), Binding("r", "refresh", "refresh")]

    def __init__(self) -> None:
        super().__init__("Look", id="look")
        self.main = "#theme-list"  # focused when the tab opens, so its keys work
        self.look: dict[str, Any] = {}

    def compose(self) -> ComposeResult:
        with Horizontal():
            with Vertical(id="look-left"):
                yield Input(placeholder="filter themes (/)", id="theme-filter")
                yield OptionList(id="theme-list")
            with Vertical(id="look-right"):
                yield Static("", id="swatch")
                yield Label("glass (Ghostty)", classes="title")
                yield OptionList(id="glass-list")

    def on_mount(self) -> None:
        self.action_refresh()

    @work(exclusive=True, group="look")
    async def action_refresh(self) -> None:
        rc, out, err = await capture("look", "--json")
        try:
            if rc:
                raise ValueError(err.strip() or f"exit {rc}")
            look = json.loads(out)
            if not isinstance(look, dict):
                raise ValueError("not an object")
        except (ValueError, json.JSONDecodeError) as e:
            self.query_one("#swatch", Static).update(Text(f"dotfiles look failed: {e}", style=tone(self.app, "$error")))
            return
        self.look = look
        self.render_themes()
        glass = self.query_one("#glass-list", OptionList)
        glass.clear_options()
        active = look.get("glass") or "default"
        glass.add_options(
            Option(f"{'● ' if lv == active else '  '}{lv}", id=lv)
            for lv in look.get("levels") or []
            if isinstance(lv, str)
        )
        if isinstance(self.app, DotfilesApp):
            self.app.apply_palette(self.palette(look.get("theme")))

    def palette(self, slug: str | None) -> dict[str, str] | None:
        """SLUG's colours, or None unless all 16 are #rrggbb."""
        for t in self.themes():
            colors = t.get("colors")
            if (
                t["slug"] == slug
                and isinstance(colors, dict)
                and all(isinstance(colors.get(k), str) and HEX.fullmatch(colors[k]) for k in BASES)
            ):
                return colors
        return None

    def themes(self) -> list[dict[str, Any]]:
        return [t for t in self.look.get("themes") or [] if isinstance(t, dict) and isinstance(t.get("slug"), str)]

    def render_themes(self) -> None:
        themes = self.query_one("#theme-list", OptionList)
        needle = self.query_one("#theme-filter", Input).value.strip().lower()
        active = self.look.get("theme")
        themes.clear_options()
        slugs = [t["slug"] for t in self.themes() if needle in t["slug"].lower()]
        themes.add_options(Option(f"{'● ' if s == active else '  '}{s}", id=s) for s in slugs)
        if active in slugs:
            themes.highlighted = slugs.index(active)
        elif slugs:
            themes.highlighted = 0
        else:
            self.query_one("#swatch", Static).update(Text("no theme matches", style="dim"))

    @on(Input.Changed, "#theme-filter")
    def filtered(self) -> None:
        self.render_themes()

    @on(Input.Submitted, "#theme-filter")
    def filter_done(self) -> None:
        self.query_one("#theme-list", OptionList).focus()

    def action_filter(self) -> None:
        self.query_one("#theme-filter", Input).focus()

    @on(OptionList.OptionHighlighted, "#theme-list")
    def preview(self, event: OptionList.OptionHighlighted) -> None:
        slug = event.option.id
        colors = self.palette(slug)
        if slug and colors:
            self.query_one("#swatch", Static).update(swatch(slug, colors))

    @on(OptionList.OptionSelected, "#theme-list")
    def pick_theme(self, event: OptionList.OptionSelected) -> None:
        if slug := event.option.id:
            self.app.push_screen(Run(f"theme {slug}", [["theme", slug]]), self.applied)

    @on(OptionList.OptionSelected, "#glass-list")
    def pick_glass(self, event: OptionList.OptionSelected) -> None:
        if level := event.option.id:
            self.app.push_screen(Run(f"glass {level}", [["glass", level]]), self.applied)

    def applied(self, _rc: int | None) -> None:
        self.action_refresh()


class DotfilesApp(App[None]):
    """The dotfiles TUI."""

    TITLE = "dotfiles"
    CSS = """
    #tool-filter, #theme-filter { margin: 0 0 1 0; }
    #tool-summary, #health-summary, #update-summary { height: 1; padding: 0 1; color: $text-muted; }
    #tool-table, #health-log, #update-log { height: 1fr; }
    #look-left { width: 34; }
    #theme-list { height: 1fr; }
    #look-right { padding: 0 2; }
    #swatch { height: auto; }
    #glass-list { height: auto; max-height: 8; }
    .title { text-style: bold; color: $accent; margin: 1 0 0 0; }
    Confirm, Run { align: center middle; }
    .dialog { width: 64; height: auto; padding: 1 2; border: round $primary; background: $surface; }
    .dialog.wide { width: 90%; height: 80%; }
    .dialog RichLog { height: 1fr; }
    .buttons { height: auto; margin: 1 0 0 0; }
    .buttons Button { margin: 0 2 0 0; }
    """
    BINDINGS = [
        Binding("q", "quit", "quit"),
        Binding("1", "tab('tools')", "tools", show=False),
        Binding("2", "tab('health')", "health", show=False),
        Binding("3", "tab('update')", "update", show=False),
        Binding("4", "tab('look')", "look", show=False),
    ]

    quit_armed = False

    async def action_quit(self) -> None:
        """Quit; while a command runs, only on a second press (it stops the command)."""
        running = any(isinstance(s, Run) and s.rc is None for s in self.screen_stack)
        if running and not self.quit_armed:
            self.quit_armed = True
            self.notify("a command is still running: quit again to stop it", severity="warning")
            return
        for proc in list(LIVE):
            await stop(proc)
        self.exit()

    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent(initial="tools"):
            yield ToolsPane()
            yield HealthPane()
            yield UpdatePane()
            yield LookPane()
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = os.uname().nodename.split(".")[0]
        # the first tab opens without a TabActivated
        self.call_after_refresh(lambda: self.query_one("#tool-table").focus())

    def apply_palette(self, colors: dict[str, str] | None) -> None:
        """Re-theme the TUI from the active base16 palette."""
        if not colors:
            return
        self.register_theme(base16_theme(colors))
        self.theme = "dotfiles"

    def action_tab(self, tab: str) -> None:
        self.query_one(TabbedContent).active = tab

    @on(TabbedContent.TabActivated)
    def tab_shown(self, event: TabbedContent.TabActivated) -> None:
        pane = event.pane
        if main := getattr(pane, "main", None):
            pane.query_one(main).focus()
        if isinstance(pane, (HealthPane, UpdatePane)) and not pane.ran:
            pane.action_check()


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print("usage: dotfiles tui  (keys: 1-4 tabs, q quit; each tab lists its own)")
        return 0
    DotfilesApp().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
