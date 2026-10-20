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

from rich.table import Table
from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.theme import Theme
from textual.widgets import (
    Button,
    DataTable,
    Footer,
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


def clip(text: str, width: int) -> str:
    """TEXT cut to WIDTH cells with an ellipsis."""
    return text if len(text) <= width else text[: width - 1] + "…"


def swatch(slug: str, colors: dict[str, str], active: bool) -> Text:
    """A card painted in the palette itself: name, the 16 colours (base00 as a
    pattern, being the card's own background) and a code sample."""
    width = 34
    bg, fg, dim = colors["base00"], colors["base05"], colors["base03"]
    t = Text()

    def line(parts: list[tuple[str, str]]) -> None:
        used = 0
        for text, style in parts:
            t.append(text, style=f"{style} on {bg}")
            used += len(text)
        t.append(" " * max(0, width - used) + "\n", style=f"on {bg}")

    line([])
    line([(" " + clip(slug, width - 2), f"bold {fg}")])
    line([(" ● active" if active else " enter applies it", dim)])
    line([])
    for row in (BASES[:8], BASES[8:]):
        cells: list[tuple[str, str]] = [(" ", fg)]
        for k in row:
            cells += [("░░░" if k == "base00" else "███", dim if k == "base00" else colors[k]), (" ", fg)]
        line(cells)
        line([(" ", fg)] + [(f"{k[4:]:<4}", dim) for k in row])
    line([])
    line([(" # switch the look", dim)])
    line([(" def ", colors["base0E"]), ("apply", colors["base0D"]), ("(theme):", fg)])
    line([("     run(", fg), ('"chezmoi"', colors["base0B"]), (", ", fg), ("3", colors["base09"]), (")", fg)])
    line([("     ", fg), ("raise ", colors["base08"]), ("Done", colors["base0C"])])
    line([])
    return t


def empty(title: str, hint: str) -> Text:
    """An empty-state message: a title line and a dim hint."""
    t = Text(justify="center")
    t.append(title + "\n", style="bold")
    t.append(hint, style="dim")
    return t


class Empty(Static, can_focus=True):
    """An empty-state panel that can hold focus, so its tab's keys work."""


class Confirm(ModalScreen[bool]):
    """Yes/no dialog with a title and a body."""

    BINDINGS = [Binding("y", "answer(True)", "yes"), Binding("n,escape", "answer(False)", "cancel")]

    def __init__(self, title: str, body: Text | str, yes: str = "Run") -> None:
        super().__init__()
        self.title_text, self.body, self.yes = title, body, yes

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog") as box:
            box.border_title = self.title_text
            yield Static(self.body, classes="body")
            with Horizontal(classes="buttons"):
                yield Button(f"{self.yes}  y", variant="primary", id="yes")
                yield Button("Cancel  n", id="no")

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
        with Vertical(classes="dialog wide") as box:
            box.border_title = self.title_text
            yield RichLog(id="run-log", wrap=True, min_width=20)
            yield Label("", id="run-status")

    def on_mount(self) -> None:
        self.query_one("#run-status", Label).update(Text("● running…", style=tone(self.app, "$accent")))
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
            status.update(Text(f"✗ failed (exit {rc}) · esc closes", style=tone(self.app, "bold $error")))
        else:
            status.update(Text("✓ done · esc closes", style=tone(self.app, "bold $success")))

    def action_close(self) -> None:
        if self.rc is None:
            self.notify("still running", severity="warning")
            return
        self.dismiss(self.rc)


class Pane(TabPane):
    """A tab with a main widget that gets focus when the tab opens, and an
    optional one-line filter (/ opens it, esc clears it)."""

    main = ""
    filter_id = ""

    def focus_main(self) -> None:
        self.query_one(self.main).focus()

    def action_filter(self) -> None:
        box = self.query_one(self.filter_id, Input)
        box.display = True
        box.focus()

    def action_clear_filter(self) -> None:
        if not self.filter_id:
            return
        box = self.query_one(self.filter_id, Input)
        box.value = ""
        box.display = False
        self.focus_main()

    @on(Input.Submitted)
    def filter_done(self, event: Input.Submitted) -> None:
        event.input.display = bool(event.value)
        self.focus_main()


class ToolsPane(Pane):
    """The tool catalog with selection and install state."""

    BINDINGS = [
        Binding("space", "toggle", "mark"),
        Binding("a", "apply", "apply"),
        Binding("slash", "filter", "filter"),
        Binding("r", "refresh", "refresh"),
        Binding("escape", "clear_filter", "clear", show=False),
    ]
    main = "#tool-table"
    filter_id = "#tool-filter"

    def __init__(self) -> None:
        super().__init__("Tools", id="tools")
        self.tools: list[dict[str, Any]] = []
        self.pending: dict[str, str] = {}
        self.error = ""

    def compose(self) -> ComposeResult:
        yield Input(placeholder="filter tools", id="tool-filter", classes="filter")
        yield DataTable(id="tool-table", cursor_type="row")
        yield Static("", id="tool-empty", classes="empty")
        yield Label("", id="tool-summary", classes="summary")

    compact: bool | None = None  # under 100 cells: no group column, shorter versions

    def on_mount(self) -> None:
        self.query_one("#tool-filter").display = False
        self.action_refresh()

    def on_resize(self) -> None:
        compact = self.size.width < 100
        if compact == self.compact:
            return
        self.compact = compact
        table = self.query_one(DataTable)
        table.clear(columns=True)
        for label, key in (
            (" ", "mark"),
            ("tool", "name"),
            ("group", "group"),
            ("source", "source"),
            ("state", "state"),
            ("version", "version"),
        ):
            if not (compact and key == "group"):
                table.add_column(label, key=key)
        self.render_rows()

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
            self.tools, self.error = [], f"dotfiles list failed: {e}"
            self.render_rows()
            return
        self.error = ""
        # off-contract items are dropped, not fatal
        self.tools = [t for t in tools if isinstance(t, dict) and isinstance(t.get("name"), str)]
        self.pending = {k: v for k, v in self.pending.items() if any(t["name"] == k for t in self.tools)}
        self.render_rows()

    def mark_cell(self, tool: dict[str, Any]) -> Text:
        match self.pending.get(tool["name"]):
            case "add":
                return Text("+", style=tone(self.app, "bold $success"))
            case "remove":
                return Text("−", style=tone(self.app, "bold $error"))
        return Text("✓", style=tone(self.app, "$primary")) if tool.get("selected") else Text("·", style="dim")

    def state_cell(self, tool: dict[str, Any]) -> Text:
        if tool.get("installed"):
            return Text("● installed", style=tone(self.app, "$success") if tool.get("selected") else "dim")
        if tool.get("selected"):
            return Text("○ missing", style=tone(self.app, "bold $error"))
        return Text("·", style="dim")

    def version_cell(self, tool: dict[str, Any]) -> Text:
        pinned, actual = field(tool, "pinned"), field(tool, "actual")
        n = 9 if self.compact else 14
        if actual and pinned and actual != pinned:
            return Text(f"{clip(actual, n)} → {clip(pinned, n)}", style=tone(self.app, "bold $warning"))
        return Text(clip(pinned or actual, 2 * n), style="" if tool.get("installed") else "dim")

    def render_rows(self) -> None:
        table = self.query_one(DataTable)
        if self.compact is None:  # columns come with the first resize
            return
        needle = self.query_one("#tool-filter", Input).value.strip().lower()
        cursor = table.cursor_row
        table.clear()
        shown = drift = missing = 0
        for t in self.tools:
            group, source = field(t, "group"), field(t, "source")
            if needle and needle not in f"{t['name']} {group} {source}".lower():
                continue
            shown += 1
            pinned, actual = field(t, "pinned"), field(t, "actual")
            drift += bool(actual and pinned and actual != pinned)
            missing += bool(t.get("selected") and not t.get("installed"))
            cells = [
                self.mark_cell(t),
                clip(t["name"], 22),
                Text(clip(group, 12), style="dim"),
                Text(clip(source, 10), style="dim"),
                self.state_cell(t),
                self.version_cell(t),
            ]
            if self.compact:
                del cells[2]
            table.add_row(*cells, key=t["name"])
        if shown:
            table.move_cursor(row=min(cursor, shown - 1))
        empty_box = self.query_one("#tool-empty", Static)
        table.display = bool(shown)
        empty_box.display = not shown
        if self.error:
            empty_box.update(empty("Couldn't load the tools", self.error))
        elif not self.tools:
            empty_box.update(empty("No tools", "the catalog is empty"))
        elif not shown:
            empty_box.update(empty(f"No tools match “{needle}”", "esc clears the filter"))
        self.render_summary(shown, missing, drift)

    def render_summary(self, shown: int, missing: int, drift: int) -> None:
        total = len(self.tools)
        t = Text(f"{shown} of {total} tools" if shown != total else f"{total} tools", style="dim")
        if missing:
            t.append(" · ", style="dim")
            t.append(f"{missing} missing", style=tone(self.app, "$error"))
        if drift:
            t.append(" · ", style="dim")
            t.append(f"{drift} off pin", style=tone(self.app, "$warning"))
        if self.pending:
            t.append(" · ", style="dim")
            t.append(f"{len(self.pending)} marked, a applies", style=tone(self.app, "bold $primary"))
        self.query_one("#tool-summary", Label).update(t)
        if isinstance(self.app, DotfilesApp):
            self.app.tool_status = (missing, drift) if self.tools else None
            self.app.render_bar()

    @on(Input.Changed, "#tool-filter")
    def filtered(self) -> None:
        self.render_rows()

    def action_toggle(self) -> None:
        table = self.query_one(DataTable)
        if not table.row_count or not table.display:
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
        body = Text()
        for verb, names, style in (("add", adds, "$success"), ("remove", removes, "$error")):
            if names:
                body.append(f"{verb:<7}", style=tone(self.app, f"bold {style}"))
                body.append(", ".join(names) + "\n")
        body.append("\nthen apply: mise installs or uninstalls, native tools print a hint", style="dim")

        def confirmed(yes: bool | None) -> None:
            if yes:
                self.app.push_screen(Run("Apply tool changes", commands), self.applied)

        self.app.push_screen(Confirm("Apply tool changes", body, yes="Apply"), confirmed)

    def applied(self, rc: int | None) -> None:
        if rc == 0:
            self.pending.clear()
        self.action_refresh()


DOCTOR_MARK = {"OK": ("✓", "$success"), "WARN": ("▲", "$warning"), "FAIL": ("✗", "$error")}


class HealthPane(Pane):
    """`dotfiles doctor`, problems first; runs only on r."""

    BINDINGS = [Binding("r", "check", "run doctor")]
    main = "#health-log"

    def __init__(self) -> None:
        super().__init__("Health", id="health")

    def compose(self) -> ComposeResult:
        yield Label("", id="health-summary", classes="summary top")
        yield Empty(
            empty("Health check", "r runs doctor · it only reads, nothing changes"), classes="empty", id="health-empty"
        )
        # no auto-scroll: the report opens at its top, problems first
        yield RichLog(id="health-log", wrap=True, min_width=20, auto_scroll=False)

    def on_mount(self) -> None:
        self.query_one("#health-log").display = False
        self.query_one("#health-summary").display = False

    def focus_main(self) -> None:
        log = self.query_one("#health-log")
        (log if log.display else self.query_one("#health-empty")).focus()

    @work(exclusive=True, group="health")
    async def action_check(self) -> None:
        log = self.query_one(RichLog)
        summary = self.query_one("#health-summary", Label)
        self.query_one("#health-empty").display = False
        log.display = summary.display = True
        log.clear()
        log.focus()
        summary.update(Text("● running doctor…", style=tone(self.app, "$accent")))
        entries: list[tuple[str, str, list[str]]] = []
        tail: list[str] = []

        def line(s: str) -> None:
            word, _, rest = s.partition(" ")
            if word in DOCTOR_MARK:
                entries.append((word, rest.strip(), []))
            elif s.startswith(" ") and entries:
                entries[-1][2].append(s.strip())
            elif s.strip():
                tail.append(s)

        rc = await stream(["doctor"], line)
        self.render_report(entries, tail, rc)

    def render_report(self, entries: list[tuple[str, str, list[str]]], tail: list[str], rc: int) -> None:
        log = self.query_one(RichLog)
        log.clear()
        counts = {k: sum(1 for e in entries if e[0] == k) for k in DOCTOR_MARK}
        problems = [e for e in entries if e[0] != "OK"]
        problems.sort(key=lambda e: e[0] != "FAIL")
        passing = [e for e in entries if e[0] == "OK"]

        def section(title: str, rows: list[tuple[str, str, list[str]]], dim: bool) -> None:
            log.write(Text(title, style=tone(self.app, "bold $accent")))
            grid = Table.grid(padding=(0, 1))
            grid.add_column(width=1)
            grid.add_column(ratio=1)
            for kind, text, details in rows:
                mark, style = DOCTOR_MARK[kind]
                body = Text(text, style="dim" if dim else "")
                for d in details:
                    body.append("\n" + d, style="dim")
                grid.add_row(Text(mark, style=tone(self.app, style)), body)
            log.write(grid)
            log.write("")

        if problems:
            section(f"Needs attention ({len(problems)})", problems, dim=False)
        if passing:
            section(f"Passing ({len(passing)})", passing, dim=True)
        for s in tail:
            log.write(Text(s, style="dim"))
        log.scroll_home(animate=False)
        t = Text()
        for kind, label in (("OK", "passing"), ("WARN", "warning"), ("FAIL", "failing")):
            mark, style = DOCTOR_MARK[kind]
            n = counts[kind]
            label += "s" if kind == "WARN" and n != 1 else ""
            t.append(f"{mark} {n} {label}", style=tone(self.app, style) if n else "dim")
            t.append("   ")
        if rc and not counts["FAIL"]:
            t.append(f"doctor exited {rc}", style=tone(self.app, "$error"))
        else:
            t.append("r runs it again", style="dim")
        self.query_one("#health-summary", Label).update(t)


class UpdatePane(Pane):
    """`dotfiles update --check` on c, `update` on u (after a confirm)."""

    BINDINGS = [Binding("c", "check", "check"), Binding("u", "update", "update")]
    main = "#update-log"

    def __init__(self) -> None:
        super().__init__("Update", id="update")

    def compose(self) -> ComposeResult:
        yield Label("", id="update-summary", classes="summary top")
        yield Empty(
            empty("Updates", "c checks what would change (fetch only) · u runs the update"),
            classes="empty",
            id="update-empty",
        )
        yield RichLog(id="update-log", wrap=True, min_width=20, auto_scroll=False)

    def on_mount(self) -> None:
        self.query_one("#update-log").display = False
        self.query_one("#update-summary").display = False

    def focus_main(self) -> None:
        log = self.query_one("#update-log")
        (log if log.display else self.query_one("#update-empty")).focus()

    section = ""

    def styled_check(self, s: str) -> Text:
        if s.startswith("==> "):
            self.section = s[4:]
            return Text("\n" + s[4:], style=tone(self.app, "bold $accent"))
        if self.section == "incoming commits" and s[:1].isalnum() and " " in s:
            sha, _, subject = s.partition(" ")
            t = Text(no_wrap=True, overflow="ellipsis")
            t.append(sha, style=tone(self.app, "$warning"))
            t.append(" " + subject)
            return t
        if s.strip() in ("(none)", "(no upstream branch to compare with)"):
            return Text(s, style="dim")
        if s.startswith("+") and not s.startswith("+++"):
            return Text(s, style=tone(self.app, "$success"))
        if s.startswith("-") and not s.startswith("---"):
            return Text(s, style=tone(self.app, "$error"))
        return styled(self.app, s)

    @work(exclusive=True, group="update")
    async def action_check(self) -> None:
        log = self.query_one(RichLog)
        summary = self.query_one("#update-summary", Label)
        self.query_one("#update-empty").display = False
        log.display = summary.display = True
        log.clear()
        log.focus()
        self.section = ""
        summary.update(Text("● checking (fetch only, nothing changes)…", style=tone(self.app, "$accent")))
        rc = await stream(["update", "--check"], lambda s: log.write(self.styled_check(s)))
        log.scroll_home(animate=False)
        if rc:
            summary.update(Text(f"✗ update --check exited {rc} · c checks again", style=tone(self.app, "$error")))
        else:
            done = Text("✓ checked", style=tone(self.app, "$success"))
            done.append("   u runs the update · c checks again", style="dim")
            summary.update(done)

    def action_update(self) -> None:
        def confirmed(yes: bool | None) -> None:
            if yes:
                # a still-streaming check would race the pull (its process group is killed)
                self.app.workers.cancel_group(self, "update")
                self.app.push_screen(Run("dotfiles update", [["update"]]), lambda _rc: self.action_check())

        body = Text(
            "git pull --ff-only, the ansible playbook, chezmoi apply, sheldon, nvim plugin restore, then doctor."
        )
        body.append("\n\nIt stops at the first failure. A dirty repo is refused.", style="dim")
        self.app.push_screen(Confirm("Update this machine", body, yes="Update"), confirmed)


class LookPane(Pane):
    """Theme and glass, with a live palette preview."""

    BINDINGS = [
        Binding("slash", "filter", "filter"),
        Binding("g", "glass", "glass"),
        Binding("t", "themes", "themes", show=False),
        Binding("r", "refresh", "refresh"),
        Binding("escape", "clear_filter", "clear", show=False),
    ]
    main = "#theme-list"

    def action_glass(self) -> None:
        glass = self.query_one("#glass-list", OptionList)
        glass.focus()
        glass.scroll_visible()

    def action_themes(self) -> None:
        self.focus_main()

    filter_id = "#theme-filter"

    def __init__(self) -> None:
        super().__init__("Look", id="look")
        self.look: dict[str, Any] = {}

    def compose(self) -> ComposeResult:
        with Horizontal():
            with Vertical(id="look-left"):
                yield Input(placeholder="filter themes", id="theme-filter", classes="filter")
                yield OptionList(id="theme-list")
            with VerticalScroll(id="look-right"):
                yield Static("", id="swatch")
                yield Label("Glass (Ghostty) · g", classes="title")
                yield OptionList(id="glass-list")

    def on_mount(self) -> None:
        self.query_one("#theme-filter").display = False
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
            self.query_one("#swatch", Static).update(empty("Couldn't load themes", f"dotfiles look failed: {e}"))
            return
        self.look = look
        self.render_themes()
        glass = self.query_one("#glass-list", OptionList)
        glass.clear_options()
        active = look.get("glass") or "default"
        glass.add_options(
            Option(f"{'●' if lv == active else ' '} {lv}", id=lv)
            for lv in look.get("levels") or []
            if isinstance(lv, str)
        )
        if isinstance(self.app, DotfilesApp):
            self.app.look_status = (field(look, "theme"), field(look, "glass") or "default")
            self.app.apply_palette(self.palette(look.get("theme")))
            self.app.render_bar()

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
        themes.add_options(Option(f"{'●' if s == active else ' '} {s}", id=s) for s in slugs)
        if active in slugs:
            themes.highlighted = slugs.index(active)
        elif slugs:
            themes.highlighted = 0
        else:
            self.query_one("#swatch", Static).update(empty(f"No themes match “{needle}”", "esc clears the filter"))

    @on(Input.Changed, "#theme-filter")
    def filtered(self) -> None:
        self.render_themes()

    @on(OptionList.OptionHighlighted, "#theme-list")
    def preview(self, event: OptionList.OptionHighlighted) -> None:
        slug = event.option.id
        colors = self.palette(slug)
        if slug and colors:
            self.query_one("#swatch", Static).update(swatch(slug, colors, slug == self.look.get("theme")))
        elif slug:
            self.query_one("#swatch", Static).update(empty(slug, "no preview: its palette is incomplete"))

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
    ENABLE_COMMAND_PALETTE = False
    CSS = """
    Screen { background: $background; }
    #bar { height: 1; padding: 0 1; background: $surface; }
    #bar-left { width: 1fr; }
    #bar-right { width: auto; }
    TabbedContent { height: 1fr; }
    TabPane { padding: 0; }
    .filter { height: 1; border: none; padding: 0 1; margin: 0 0 0 0; background: $surface; }
    .filter:focus { border: none; background-tint: $primary 10%; }
    DataTable { height: 1fr; background: $background; scrollbar-size-vertical: 1; }
    DataTable > .datatable--header { background: $background; color: $text-muted; text-style: bold; }
    DataTable > .datatable--cursor { background: $primary 25%; }
    DataTable:focus > .datatable--cursor { background: $primary 35%; }
    .empty { height: 1fr; content-align: center middle; color: $text; }
    .summary { height: 1; width: 1fr; padding: 0 1; background: $surface; text-wrap: nowrap; text-overflow: ellipsis; }
    .summary.top { background: $background; padding: 1 1 0 1; height: 2; }
    RichLog { height: 1fr; padding: 0 1; background: $background; scrollbar-size-vertical: 1; }
    #look-left { width: 38; border-right: tall $surface; }
    #theme-list { height: 1fr; border: none; padding: 0; background: $background; scrollbar-size-vertical: 1; }
    #theme-list > .option-list--option { padding: 0 0 0 1; }
    #look-right { padding: 1 2; scrollbar-size-vertical: 1; }
    #swatch { height: auto; width: auto; }
    #glass-list { height: auto; max-height: 7; border: none; background: $background; width: 24; }
    .title { text-style: bold; color: $accent; margin: 1 0 0 0; }
    Confirm, Run { align: center middle; background: $background 60%; }
    .dialog { width: 70; max-width: 95%; height: auto; padding: 1 2; border: round $primary;
              border-title-color: $primary; border-title-style: bold; background: $surface; }
    .dialog.wide { width: 95%; height: 85%; }
    .dialog .body { height: auto; }
    .dialog RichLog { height: 1fr; background: $surface; padding: 0; }
    #run-status { height: 1; margin: 1 0 0 0; }
    .buttons { height: auto; margin: 1 0 0 0; align-horizontal: right; }
    .buttons Button { margin: 0 0 0 2; min-width: 12; }
    """
    BINDINGS = [
        Binding("q", "quit", "quit"),
        Binding("1", "tab('tools')", "tools", show=False),
        Binding("2", "tab('health')", "health", show=False),
        Binding("3", "tab('update')", "update", show=False),
        Binding("4", "tab('look')", "look", show=False),
    ]

    quit_armed = False
    tool_status: tuple[int, int] | None = None
    look_status: tuple[str, str] | None = None

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
        with Horizontal(id="bar"):
            yield Label("", id="bar-left")
            yield Label("", id="bar-right")
        with TabbedContent(initial="tools"):
            yield ToolsPane()
            yield HealthPane()
            yield UpdatePane()
            yield LookPane()
        yield Footer()

    def on_mount(self) -> None:
        self.render_bar()
        # the first tab opens without a TabActivated
        self.call_after_refresh(lambda: self.query_one("#tool-table").focus())

    def render_bar(self) -> None:
        wide = self.size.width >= 140
        left = Text()
        left.append("dotfiles", style=tone(self, "bold $primary"))
        if wide:
            left.append(f"  {os.uname().nodename.split('.')[0]}", style="dim")
        if self.look_status:
            theme, glass = self.look_status
            theme = clip(theme or "default theme", 34 if wide else 20)
            left.append(f"  ·  {theme}  ·  {'glass ' if wide else ''}{glass}", style="dim")
        right = Text("  ")
        if self.tool_status:
            missing, drift = self.tool_status
            if missing:
                right.append(f"○ {missing} missing  ", style=tone(self, "$error"))
            if drift:
                right.append(f"→ {drift} off pin  ", style=tone(self, "$warning"))
            if not (missing or drift):
                right.append("✓ tools in sync  ", style=tone(self, "$success"))
        if wide:
            right.append("1-4 tabs", style="dim")
        self.query_one("#bar-left", Label).update(left)
        self.query_one("#bar-right", Label).update(right)

    def on_resize(self) -> None:
        self.render_bar()

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
        # Opening a tab only moves focus: nothing runs until its key is pressed.
        if isinstance(event.pane, Pane):
            event.pane.focus_main()


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print("usage: dotfiles tui  (keys: 1-4 tabs, q quit; each tab lists its own)")
        return 0
    DotfilesApp().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
