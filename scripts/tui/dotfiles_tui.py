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
from textual import events, on, work
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
    Tabs,
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
        self.want = ""  # a row to put the cursor on once it exists

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
        if isinstance(self.app, DotfilesApp):
            self.app.tools_data = self.tools
            self.app.data_changed()

    def select(self, name: str) -> None:
        """Clear the filter and put the cursor on NAME."""
        box = self.query_one("#tool-filter", Input)
        if box.value:
            box.value = ""
            box.display = False
            self.render_rows()
        # the rows may not exist yet (columns come with the first resize)
        self.want = name
        self.render_rows()
        self.focus_main()

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
            if self.want and self.want in [str(k.value) for k in table.rows]:
                table.move_cursor(row=table.get_row_index(self.want))
                self.want = ""
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


def parse_doctor(out: str) -> list[tuple[str, str, list[str]]]:
    """doctor output as (OK|WARN|FAIL, text, detail lines)."""
    entries: list[tuple[str, str, list[str]]] = []
    for s in out.splitlines():
        word, _, rest = s.partition(" ")
        if word in DOCTOR_MARK:
            entries.append((word, rest.strip(), []))
        elif s.startswith(" ") and s.strip() and entries:
            entries[-1][2].append(s.strip())
    return entries


def parse_check(out: str) -> dict[str, list[str]]:
    """update --check output as {section: lines}."""
    sections: dict[str, list[str]] = {}
    current = ""
    for s in out.splitlines():
        if s.startswith("==> "):
            current = s[4:]
            sections[current] = []
        elif current and s.strip() and s.strip() not in ("(none)",):
            sections[current].append(s)
    return sections


class StatusPane(Pane):
    """Is this machine healthy and in sync? Cards, then what needs attention."""

    BINDINGS = [
        Binding("r", "check", "check health + updates"),
        Binding("u", "update", "update"),
        Binding("enter", "open", "open", show=False),
    ]
    main = "#attention"

    def __init__(self) -> None:
        super().__init__("Status", id="status")
        self.doctor: list[tuple[str, str, list[str]]] | None = None
        self.doctor_rc = 0
        self.check: dict[str, list[str]] | None = None
        self.check_rc = 0
        self.checking = False
        self.doctor_error = ""
        self.details: dict[str, Text] = {}

    def compose(self) -> ComposeResult:
        with Horizontal(id="cards"):
            for card in ("health", "updates", "files", "tools"):
                yield Static("", id=f"card-{card}", classes="card")
        yield Label("Needs attention", classes="title")
        yield OptionList(id="attention")
        yield Static("", id="status-detail")

    def on_mount(self) -> None:
        for card, title in (("health", "Health"), ("updates", "Updates"), ("files", "Files"), ("tools", "Tools")):
            self.query_one(f"#card-{card}").border_title = title
        self.render_status()

    @work(exclusive=True, group="status")
    async def action_check(self) -> None:
        self.checking = True
        self.render_status()
        self.doctor_rc, out, err = await capture("doctor")
        self.doctor = parse_doctor(out)
        # no checks at all: doctor itself didn't run
        self.doctor_error = "" if self.doctor else (err.strip() or out.strip() or f"exit {self.doctor_rc}")
        self.render_status()
        self.check_rc, out, _ = await capture("update", "--check")
        self.check = parse_check(out)
        self.checking = False
        self.render_status()

    def action_update(self) -> None:
        def confirmed(yes: bool | None) -> None:
            if yes:
                self.app.workers.cancel_group(self, "status")
                self.app.push_screen(Run("dotfiles update", [["update"]]), self.updated)

        body = Text(
            "git pull --ff-only, the ansible playbook, chezmoi apply, sheldon, nvim plugin restore, then doctor."
        )
        body.append("\n\nIt stops at the first failure and refuses a dirty repo.", style="dim")
        local = [f for f in self.app_files() if f.get("local")]
        if local:
            body.append(
                f"\n\n▲ {len(local)} file(s) changed here would be overwritten: keep them in Files first.",
                style=tone(self.app, "bold $warning"),
            )
        self.app.push_screen(Confirm("Update this machine", body, yes="Update"), confirmed)

    def updated(self, _rc: int | None) -> None:
        if isinstance(self.app, DotfilesApp):
            self.app.reload_all()
        self.action_check()

    def app_tools(self) -> list[dict[str, Any]]:
        return getattr(self.app, "tools_data", None) or []

    def app_files(self) -> list[dict[str, Any]]:
        return getattr(self.app, "files_data", None) or []

    def card(self, name: str, lines: list[tuple[str, str]]) -> None:
        t = Text()
        for i, (text, style) in enumerate(lines):
            t.append(("\n" if i else "") + text, style=tone(self.app, style) if "$" in style else style)
        self.query_one(f"#card-{name}", Static).update(t)

    def render_status(self) -> None:
        tools, files = self.app_tools(), self.app_files()
        # health
        if self.doctor is None:
            self.card(
                "health",
                [("● checking…", "$accent")] if self.checking else [("not checked", "dim"), ("r checks", "dim")],
            )
        elif self.doctor_error:
            self.card("health", [("✗ doctor didn't run", "bold $error"), ("r tries again", "dim")])
        else:
            n = {k: sum(1 for e in self.doctor if e[0] == k) for k in DOCTOR_MARK}
            first = f"✗ {n['FAIL']} failing" if n["FAIL"] else ("▲ " if n["WARN"] else "✓ ") + "healthy"
            style = "bold $error" if n["FAIL"] else ("$warning" if n["WARN"] else "$success")
            self.card("health", [(first, style), (f"{n['WARN']} warn · {n['OK']} ok", "dim")])
        # updates
        if self.check is None:
            busy = self.checking and self.doctor is not None
            self.card(
                "updates", [("● fetching…", "$accent")] if busy else [("not checked", "dim"), ("r checks", "dim")]
            )
        else:
            commits = self.check.get("incoming commits", [])
            commits = [c for c in commits if not c.startswith("(")]
            if self.check_rc:
                self.card("updates", [("✗ check failed", "$error"), ("r tries again", "dim")])
            elif commits:
                self.card("updates", [(f"↓ {len(commits)} incoming", "bold $warning"), ("u updates", "dim")])
            else:
                self.card("updates", [("✓ up to date", "$success"), ("nothing to pull", "dim")])
        # files
        local = [f for f in files if f.get("local")]
        pending = [f for f in files if f.get("pending") and not f.get("local")]
        if getattr(self.app, "files_data", None) is None:
            self.card("files", [("loading…", "dim")])
        else:
            first = (f"● {len(local)} edited", "bold $warning") if local else ("✓ no local edits", "$success")
            self.card("files", [first, (f"{len(pending)} to apply", "dim")])
        # tools
        missing = [t for t in tools if t.get("selected") and not t.get("installed")]
        drift = [
            t for t in tools if field(t, "actual") and field(t, "pinned") and field(t, "actual") != field(t, "pinned")
        ]
        if getattr(self.app, "tools_data", None) is None:
            self.card("tools", [("loading…", "dim")])
        else:
            first = (f"○ {len(missing)} missing", "bold $error") if missing else ("✓ all installed", "$success")
            self.card("tools", [first, (f"{len(drift)} off pin · {len(tools)}", "dim")])
        self.render_attention(missing, drift, local, pending)

    def render_attention(self, missing, drift, local, pending) -> None:
        items: list[tuple[str, Text, Text]] = []

        def add(key: str, mark: str, style: str, text: str, hint: str, detail: Text | None = None) -> None:
            width = max(20, self.size.width - len(hint) - 8)
            prompt = Text(no_wrap=True, overflow="ellipsis")
            prompt.append(f"{mark} ", style=tone(self.app, style))
            prompt.append(clip(text, width))
            prompt.append(f"   {hint}", style="dim")
            items.append((key, prompt, detail or Text(text)))

        if self.doctor_error:
            add("doctor:error", "✗", "$error", "doctor didn't run", "r tries again", Text(self.doctor_error))
        # failures first, then warnings, each in doctor's order
        ranked = sorted(enumerate(self.doctor or []), key=lambda e: e[1][0] != "FAIL")
        for i, (kind, text, details) in ranked:
            if kind == "OK":
                continue
            mark, style = DOCTOR_MARK[kind]
            d = Text(text)
            for line in details:
                d.append("\n" + line, style="dim")
            add(f"doctor:{i}", mark, style, text, "doctor", d)
        for f in local:
            add(f"file:{f['path']}", "●", "$warning", f"{f['path']} changed here", "enter: Files")
        for t in missing:
            add(f"tool:{t['name']}", "○", "$error", f"{t['name']} is selected but not installed", "enter: Tools")
        for t in drift:
            add(
                f"tool:{t['name']}",
                "→",
                "$warning",
                f"{t['name']} {field(t, 'actual')} → pinned {field(t, 'pinned')}",
                "enter: Tools",
            )
        commits = [c for c in (self.check or {}).get("incoming commits", []) if not c.startswith("(")]
        if commits:
            d = Text("\n".join(commits[:20]) + (f"\n… {len(commits) - 20} more" if len(commits) > 20 else ""))
            add("commits", "↓", "$warning", f"{len(commits)} incoming commit(s)", "u updates", d)
        if pending:
            d = Text("\n".join(f["path"] for f in pending[:20]), style="dim")
            add("pending", "◌", "$primary", f"{len(pending)} file(s) waiting to apply", "enter: Files", d)

        attention = self.query_one("#attention", OptionList)
        keep = attention.highlighted
        attention.clear_options()
        self.details = {k: d for k, _, d in items}
        detail = self.query_one("#status-detail", Static)
        if items:
            attention.display = True
            attention.add_options(Option(p, id=k) for k, p, _ in items)
            attention.highlighted = min(keep or 0, len(items) - 1)
        else:
            attention.display = False
            if self.doctor is None:
                detail.update(empty("Nothing flagged yet", "r checks health and updates · it only reads and fetches"))
            else:
                detail.update(empty("All clear", "healthy, in sync, nothing changed here"))

    @on(OptionList.OptionHighlighted, "#attention")
    def show_detail(self, event: OptionList.OptionHighlighted) -> None:
        if (key := event.option.id) in self.details:
            self.query_one("#status-detail", Static).update(self.details[key])

    @on(OptionList.OptionSelected, "#attention")
    def open_item(self, event: OptionList.OptionSelected) -> None:
        key = event.option.id or ""
        app = self.app
        if not isinstance(app, DotfilesApp):
            return
        if key.startswith("file:") or key == "pending":
            app.action_tab("files")
            app.query_one(FilesPane).select(key[5:] if key.startswith("file:") else None)
        elif key.startswith("tool:"):
            app.action_tab("tools")
            app.query_one(ToolsPane).select(key[5:])
        elif key == "commits":
            self.action_update()

    def action_open(self) -> None:
        attention = self.query_one("#attention", OptionList)
        if attention.highlighted is not None:
            attention.action_select()


class FilesPane(Pane):
    """Managed files changed here (keep or discard) or waiting to apply."""

    BINDINGS = [
        Binding("a", "apply", "apply"),
        Binding("k", "keep", "keep mine"),
        Binding("A", "apply_all", "apply all waiting"),
        Binding("slash", "filter", "filter"),
        Binding("r", "refresh", "refresh"),
        Binding("escape", "clear_filter", "clear", show=False),
    ]
    main = "#file-list"
    filter_id = "#file-filter"

    def __init__(self) -> None:
        super().__init__("Files", id="files")
        self.files: list[dict[str, Any]] = []
        self.error = ""

    def compose(self) -> ComposeResult:
        with Horizontal():
            with Vertical(id="files-left"):
                yield Input(placeholder="filter files", id="file-filter", classes="filter")
                yield OptionList(id="file-list")
            with Vertical(id="files-right"):
                yield Label("", id="file-head", classes="summary top")
                yield RichLog(id="file-diff", wrap=False, min_width=20, auto_scroll=False)

    def on_mount(self) -> None:
        self.query_one("#file-filter").display = False
        self.action_refresh()

    @work(exclusive=True, group="files")
    async def action_refresh(self) -> None:
        rc, out, err = await capture("files", "--json")
        try:
            if rc:
                raise ValueError(err.strip() or f"exit {rc}")
            files = json.loads(out)
            if not isinstance(files, list):
                raise ValueError("not a list")
            self.files = [f for f in files if isinstance(f, dict) and isinstance(f.get("path"), str)]
            self.error = ""
        except (ValueError, json.JSONDecodeError) as e:
            self.files, self.error = [], f"dotfiles files failed: {e}"
        if isinstance(self.app, DotfilesApp):
            self.app.files_data = None if self.error else self.files
            self.app.data_changed()
        self.render_files()

    def render_files(self, select: str | None = None) -> None:
        lst = self.query_one("#file-list", OptionList)
        needle = self.query_one("#file-filter", Input).value.strip().lower()
        keep = select or (lst.get_option_at_index(lst.highlighted).id if lst.highlighted is not None else None)
        lst.clear_options()
        shown = [f for f in self.files if needle in f["path"].lower()]
        local = [f for f in shown if f.get("local")]
        waiting = [f for f in shown if f.get("pending") and not f.get("local")]
        options: list[Option] = []
        for title, group, mark, style in (
            ("Changed here", local, "●", "$warning"),
            ("Waiting to apply", waiting, "◌", "$primary"),
        ):
            if not group:
                continue
            options.append(Option(Text(f"{title} ({len(group)})", style=tone(self.app, "bold $accent")), disabled=True))
            for f in group:
                p = Text()
                p.append(f"{mark} ", style=tone(self.app, style))
                room = max(16, lst.size.width - 6) if lst.size.width else 42
                tmpl = " tmpl" if f.get("template") else ""
                p.append(clip(f["path"], room - len(tmpl)))
                p.append(tmpl, style="dim")
                options.append(Option(p, id=f["path"]))
        lst.add_options(options)
        head = self.query_one("#file-head", Label)
        diff = self.query_one("#file-diff", RichLog)
        if not options:
            diff.clear()
            if self.error:
                head.update(Text(self.error, style=tone(self.app, "$error")))
            elif needle:
                head.update(Text(f"No files match “{needle}” · esc clears the filter", style="dim"))
            else:
                head.update(
                    Text(
                        "✓ Everything matches the repo: nothing changed here, nothing waiting",
                        style=tone(self.app, "$success"),
                    )
                )
            return
        ids = [o.id for o in options]
        # headers have no id: never keep (or land) on one
        idx = ids.index(keep) if keep and keep in ids else next(i for i, o in enumerate(options) if not o.disabled)
        lst.highlighted = idx

    def on_resize(self) -> None:
        self.render_files()

    def select(self, path: str | None) -> None:
        if path:
            self.render_files(select=path)
        self.focus_main()

    def current(self) -> dict[str, Any] | None:
        lst = self.query_one("#file-list", OptionList)
        if lst.highlighted is None:
            return None
        oid = lst.get_option_at_index(lst.highlighted).id
        return next((f for f in self.files if f["path"] == oid), None)

    @on(Input.Changed, "#file-filter")
    def filtered(self) -> None:
        self.render_files()

    @on(OptionList.OptionHighlighted, "#file-list")
    def highlighted(self) -> None:
        self.load_diff()

    @work(exclusive=True, group="diff")
    async def load_diff(self) -> None:
        f = self.current()
        head = self.query_one("#file-head", Label)
        diff = self.query_one("#file-diff", RichLog)
        if not f:
            return
        await asyncio.sleep(0.12)  # debounce: holding ↓ doesn't run a diff per row
        t = Text()
        if f.get("local"):
            t.append("● changed here\n", style=tone(self.app, "bold $warning"))
            t.append("a discards yours for the repo's · k keeps yours", style="dim")
        else:
            t.append("◌ waiting to apply\n", style=tone(self.app, "bold $primary"))
            t.append("a applies it · A applies all waiting", style="dim")
        head.update(t)
        rc, out, err = await capture("files", "diff", f["path"])
        diff.clear()
        if rc:
            diff.write(Text(err.strip() or f"diff failed (exit {rc})", style=tone(self.app, "$error")))
            return
        diff.write(Text("- this machine   + after apply", style="dim"))
        for line in out.splitlines() or ["(no content difference: mode or script only)"]:
            if line.startswith("+") and not line.startswith("+++"):
                diff.write(Text(line, style=tone(self.app, "$success")))
            elif line.startswith("-") and not line.startswith("---"):
                diff.write(Text(line, style=tone(self.app, "$error")))
            elif line.startswith("@@"):
                diff.write(Text(line, style=tone(self.app, "$accent")))
            else:
                diff.write(Text(line, style="dim"))

    def action_apply(self) -> None:
        f = self.current()
        if not f:
            return
        if not f.get("local"):
            self.app.push_screen(Run(f"apply {f['path']}", [["files", "apply", f["path"]]]), self.done)
            return
        body = Text(f"{f['path']}\n\n", style="bold")
        body.append("Your edits here are replaced with the repo's version. They are not saved anywhere.")

        def confirmed(yes: bool | None) -> None:
            if yes:
                self.app.push_screen(Run(f"apply {f['path']}", [["files", "apply", f["path"]]]), self.done)

        self.app.push_screen(Confirm("Discard local edits?", body, yes="Discard"), confirmed)

    def action_keep(self) -> None:
        f = self.current()
        if not f:
            return
        if not f.get("local"):
            self.notify("only a file changed here can be kept")
            return
        if f.get("template"):
            self.notify("this file comes from a template: edit the template in the repo", severity="warning")
            return
        body = Text(f"{f['path']}\n\n", style="bold")
        body.append("Your version is copied into the repo (chezmoi re-add). Commit it there to keep it.")

        def confirmed(yes: bool | None) -> None:
            if yes:
                self.app.push_screen(Run(f"keep {f['path']}", [["files", "keep", f["path"]]]), self.done)

        self.app.push_screen(Confirm("Keep my version", body, yes="Keep"), confirmed)

    def action_apply_all(self) -> None:
        waiting = [f["path"] for f in self.files if f.get("pending") and not f.get("local")]
        if not waiting:
            self.notify("nothing is waiting to apply")
            return
        body = Text(f"Apply {len(waiting)} file(s) from the repo. Files changed here are left alone.")

        def confirmed(yes: bool | None) -> None:
            if yes:
                self.app.push_screen(Run("apply waiting files", [["files", "apply", *waiting]]), self.done)

        self.app.push_screen(Confirm("Apply waiting files", body, yes="Apply"), confirmed)

    def done(self, _rc: int | None) -> None:
        self.action_refresh()


MACHINE_FIELDS = [
    ("git_name", "Git name", "commit author name"),
    ("git_email", "Git email", "commit author email"),
    ("personal_git_name", "Personal name", "identity for your personal repos"),
    ("personal_git_email", "Personal email", "prefer GitHub's noreply address"),
    ("personal_git_dirs", "Personal dirs", "where it applies, comma-separated; trailing / = beneath"),
    ("signing_key", "Signing key", "SSH .pub that signs personal commits"),
    ("allow_sudo", "Allow sudo", "native package installs may use sudo"),
]


class Edit(ModalScreen[str | None]):
    """One-field editor; dismisses with the new value, or None on cancel."""

    BINDINGS = [Binding("escape", "cancel", "cancel")]

    def __init__(self, title: str, value: str, hint: str) -> None:
        super().__init__()
        self.title_text, self.value, self.hint = title, value, hint

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog") as box:
            box.border_title = self.title_text
            yield Input(self.value, id="edit-value")
            yield Static(Text(self.hint + "\nenter saves · esc cancels · empty unsets", style="dim"), classes="body")

    def on_mount(self) -> None:
        self.query_one(Input).focus()

    @on(Input.Submitted)
    def save(self, event: Input.Submitted) -> None:
        self.dismiss(event.value)

    def action_cancel(self) -> None:
        self.dismiss(None)


class MachinePane(Pane):
    """This machine's install.sh answers (ansible/local.yml)."""

    BINDINGS = [
        Binding("enter", "edit", "edit"),
        Binding("a", "apply", "apply to this machine"),
        Binding("r", "refresh", "refresh"),
    ]
    main = "#machine-table"

    def __init__(self) -> None:
        super().__init__("Machine", id="machine")
        self.data: dict[str, Any] = {}
        self.dirty = False

    def compose(self) -> ComposeResult:
        yield DataTable(id="machine-table", cursor_type="row")
        yield Label("", id="machine-summary", classes="summary")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_column("setting", key="label")
        table.add_column("value", key="value")
        table.add_column("", key="about")
        self.action_refresh()

    @work(exclusive=True, group="machine")
    async def action_refresh(self) -> None:
        rc, out, err = await capture("machine", "--json")
        try:
            if rc:
                raise ValueError(err.strip() or f"exit {rc}")
            data = json.loads(out)
            if not isinstance(data, dict) or not isinstance(data.get("values"), dict):
                raise ValueError("not an object")
        except (ValueError, json.JSONDecodeError) as e:
            self.data = {}
            self.query_one("#machine-summary", Label).update(
                Text(f"dotfiles machine failed: {e}", style=tone(self.app, "$error"))
            )
            return
        self.data = data
        self.render_rows()

    @staticmethod
    def show(value: Any) -> str:
        if value is None:
            return ""
        if isinstance(value, bool):
            return "yes" if value else "no"
        if isinstance(value, list):
            return ", ".join(str(v) for v in value)
        return str(value)

    def render_rows(self) -> None:
        table = self.query_one(DataTable)
        cursor = table.cursor_row
        table.clear()
        values = self.data.get("values", {})
        for key, label, about in MACHINE_FIELDS:
            v = self.show(values.get(key))
            cell = Text(clip(v, 40)) if v else Text("—", style="dim")
            if key == "signing_key" and v:
                ok = (self.data.get("signing") or {}).get("exists")
                cell.append(
                    "  ✓ found" if ok else "  ✗ file missing", style=tone(self.app, "$success" if ok else "$error")
                )
            table.add_row(Text(label, style="bold"), cell, Text(about, style="dim"), key=key)
        groups = values.get("tool_groups")
        sel = self.show(groups) if groups else "every group"
        extra = [
            f"+{self.show(values.get('tools_add'))}" if values.get("tools_add") else "",
            f"−{self.show(values.get('tools_remove'))}" if values.get("tools_remove") else "",
        ]
        sel += "".join(f"  {e}" for e in extra if e)
        table.add_row(
            Text("Tools", style="dim bold"),
            Text(clip(sel, 40), style="dim"),
            Text("change in the Tools tab", style="dim"),
            key="-tools",
        )
        shared = self.show(values.get("shared_home")) or "no"
        table.add_row(
            Text("Shared home", style="dim bold"),
            Text(shared, style="dim"),
            Text("set at install; re-run install.sh --reconfigure", style="dim"),
            key="-shared",
        )
        table.move_cursor(row=min(cursor, table.row_count - 1))
        path = str(self.data.get("path", ""))
        home = os.path.expanduser("~")
        path = "~" + path[len(home) :] if path.startswith(home + "/") else path
        s = Text(clip(path, 60), style="dim")
        if not self.data.get("exists"):
            s = Text("no local.yml yet: run install.sh first", style=tone(self.app, "$error"))
        elif self.dirty:
            s.append("   ● saved to local.yml · a applies it to this machine", style=tone(self.app, "bold $warning"))
        self.query_one("#machine-summary", Label).update(s)

    @on(DataTable.RowSelected, "#machine-table")
    def row_selected(self) -> None:
        # DataTable keeps enter for itself; selecting a row edits it
        self.action_edit()

    def action_edit(self) -> None:
        table = self.query_one(DataTable)
        if not table.row_count or not self.data.get("exists"):
            return
        key = str(table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value)
        meta = next((f for f in MACHINE_FIELDS if f[0] == key), None)
        if not meta:
            self.notify(
                "read-only here: " + ("use the Tools tab" if key == "-tools" else "re-run install.sh --reconfigure")
            )
            return
        value = self.data["values"].get(key)
        if key == "allow_sudo":
            self.save(key, "false" if value else "true")
            return
        hint = meta[2] + (" (must end in .pub)" if key == "signing_key" else "")

        def edited(new: str | None) -> None:
            if new is not None and new != self.show(value):
                self.save(key, new)

        self.app.push_screen(Edit(meta[1], self.show(value), hint), edited)

    def save(self, key: str, value: str) -> None:
        def saved(rc: int | None) -> None:
            if rc == 0:
                self.dirty = True
            self.action_refresh()

        self.app.push_screen(Run(f"set {key}", [["machine", "set", key, value, "--no-apply"]]), saved)

    def action_apply(self) -> None:
        body = Text("Rewrites chezmoi's config from local.yml, then runs chezmoi apply.")
        body.append("\n\nFiles changed here are not overwritten: apply stops and Files lists them.", style="dim")

        def confirmed(yes: bool | None) -> None:
            if yes:
                self.app.push_screen(Run("apply machine settings", [["machine", "apply"]]), self.applied)

        self.app.push_screen(Confirm("Apply to this machine", body, yes="Apply"), confirmed)

    def applied(self, rc: int | None) -> None:
        if rc == 0:
            self.dirty = False
        self.action_refresh()
        if isinstance(self.app, DotfilesApp):
            self.app.reload_all()


class LookPane(Pane):
    """Theme and glass, with a live palette preview."""

    BINDINGS = [
        Binding("slash", "filter", "filter"),
        Binding("g", "glass", "glass"),
        Binding("w", "wallpaper", "wallpaper"),
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
                yield Label("Wallpaper · w", classes="title")
                yield Static("", id="wallpaper")

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
        wall = field(look, "wallpaper") or "off"
        w = Text()
        w.append("● on" if wall == "on" else "○ off", style=tone(self.app, "$success") if wall == "on" else "dim")
        w.append("   w toggles the themed terminal background", style="dim")
        self.query_one("#wallpaper", Static).update(w)
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

    def action_wallpaper(self) -> None:
        self.app.push_screen(Run("wallpaper toggle", [["wallpaper", "toggle"]]), self.applied)

    def applied(self, _rc: int | None) -> None:
        self.action_refresh()
        if isinstance(self.app, DotfilesApp):
            self.app.query_one(FilesPane).action_refresh()


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
    #wallpaper { height: 1; padding: 0 0 0 2; }
    #cards { height: 5; padding: 1 1 0 1; }
    .card { width: 1fr; height: 4; border: round $surface; border-title-color: $text-muted; padding: 0 1;
            margin: 0 1 0 0; }
    #status .title { padding: 0 1; }
    #attention { height: 1fr; max-height: 14; border: none; background: $background; padding: 0 1;
                  scrollbar-size-vertical: 1; }
    #status-detail { height: 1fr; padding: 1 2; color: $text; border-top: solid $surface; }
    #files-left { width: 45%; max-width: 64; border-right: tall $surface; }
    #file-head { height: 3; padding: 1 0 0 0; }
    #file-list { height: 1fr; border: none; background: $background; scrollbar-size-vertical: 1; }
    #files-right { padding: 0 1; }
    #file-diff { height: 1fr; }
    #machine-table { height: 1fr; }
    Edit { align: center middle; background: $background 60%; }
    #edit-value { margin: 0 0 1 0; }
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
        Binding("1", "tab('status')", "status", show=False),
        Binding("2", "tab('tools')", "tools", show=False),
        Binding("3", "tab('files')", "files", show=False),
        Binding("4", "tab('look')", "look", show=False),
        Binding("5", "tab('machine')", "machine", show=False),
    ]

    quit_armed = False
    look_status: tuple[str, str] | None = None
    # shared with the Status tab and the bar; None until loaded (or on error)
    tools_data: list[dict[str, Any]] | None = None
    files_data: list[dict[str, Any]] | None = None

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
        with TabbedContent(initial="status"):
            yield StatusPane()
            yield ToolsPane()
            yield FilesPane()
            yield LookPane()
            yield MachinePane()
        yield Footer()

    def on_mount(self) -> None:
        self.render_bar()
        # the first tab opens without a TabActivated
        self.call_after_refresh(lambda: self.query_one(StatusPane).focus_main())

    def data_changed(self) -> None:
        """Tools or files reloaded: refresh what summarises them."""
        self.query_one(StatusPane).render_status()
        self.render_bar()

    def reload_all(self) -> None:
        """After a command that may change anything (update, machine apply)."""
        self.query_one(ToolsPane).action_refresh()
        self.query_one(FilesPane).action_refresh()
        self.query_one(LookPane).action_refresh()
        self.query_one(MachinePane).action_refresh()

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
        tools, files = self.tools_data or [], self.files_data or []
        missing = sum(1 for t in tools if t.get("selected") and not t.get("installed"))
        local = sum(1 for f in files if f.get("local"))
        if missing:
            right.append(f"○ {missing} missing  ", style=tone(self, "$error"))
        if local:
            right.append(f"● {local} edited here  ", style=tone(self, "$warning"))
        if self.tools_data is not None and self.files_data is not None and not (missing or local):
            right.append("✓ in sync  ", style=tone(self, "$success"))
        if wide:
            right.append("1-5 tabs", style="dim")
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
        tabs = self.query_one(TabbedContent)
        tabs.active = tab
        if isinstance(pane := tabs.get_pane(tab), Pane):
            pane.focus_main()

    @on(TabbedContent.TabActivated)
    def tab_shown(self, event: TabbedContent.TabActivated) -> None:
        # Opening a tab only moves focus, and not while browsing the tab bar
        # (←/→ keep going): nothing runs until a tab's own key is pressed.
        if isinstance(self.focused, Tabs):
            return
        if isinstance(event.pane, Pane):
            event.pane.focus_main()

    def on_key(self, event: events.Key) -> None:
        # ↓ or enter on the tab bar steps into the open tab
        if isinstance(self.focused, Tabs) and event.key in ("down", "enter"):
            pane = self.query_one(TabbedContent).active_pane
            if isinstance(pane, Pane):
                event.stop()
                pane.focus_main()


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print("usage: dotfiles tui  (keys: 1-5 tabs, q quit; each tab lists its own)")
        return 0
    DotfilesApp().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
