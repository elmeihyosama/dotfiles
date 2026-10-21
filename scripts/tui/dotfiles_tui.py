#!/usr/bin/env -S uv run --quiet --locked --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["textual==8.2.8", "pillow==12.3.0"]
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
import time
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path
from typing import Any

from rich.color import Color, ColorType
from rich.style import Style
from rich.table import Table
from rich.text import Text
from textual import events, on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.theme import Theme
from textual.widget import Widget
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Input,
    Label,
    OptionList,
    RichLog,
    Static,
    Switch,
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
        env=child_env(),
        start_new_session=True,
    )
    LIVE.add(proc)
    return proc


def child_env() -> dict[str, str]:
    """os.environ for the CLI, minus this TUI's own Python (uv puts its
    environment first on PATH; ansible would run its modules with it)."""
    env = {**os.environ, **CHILD_ENV}
    here = os.path.dirname(sys.executable)
    env["PATH"] = os.pathsep.join(d for d in env.get("PATH", "").split(os.pathsep) if d and d != here)
    env.pop("VIRTUAL_ENV", None)
    return env


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
    """The tool catalog: a table, and the highlighted tool explained beside it."""

    BINDINGS = [
        Binding("space", "toggle", "mark"),
        Binding("a", "apply", "apply marks"),
        Binding("i", "install", "install missing"),
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
        with Horizontal():
            with Vertical(id="tools-box", classes="box"):
                yield Input(placeholder="filter tools", id="tool-filter", classes="filter")
                yield DataTable(id="tool-table", cursor_type="row")
                yield Static("", id="tool-empty", classes="empty")
                yield Label("", id="tool-summary", classes="summary")
            with VerticalScroll(id="tool-detail-box", classes="box side"):
                yield Static("", id="tool-detail")

    compact: bool | None = None  # under 100 cells: no About panel, shorter versions

    def on_mount(self) -> None:
        self.query_one("#tool-filter").display = False
        self.query_one("#tools-box").border_title = "Tools"
        self.query_one("#tool-detail-box").border_title = "About"
        self.action_refresh()

    def on_resize(self) -> None:
        compact = self.size.width < 100
        if compact == self.compact:
            return
        self.compact = compact
        self.query_one("#tool-detail-box").display = not compact
        table = self.query_one(DataTable)
        if not table.columns:
            for label, key in ((" ", "mark"), ("tool", "name"), ("state", "state"), ("version", "version")):
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
        # the rows may not exist yet (columns come with the first resize)
        self.want = name
        self.render_rows()
        self.focus_main()

    def mark_cell(self, tool: dict[str, Any]) -> Text:
        match self.pending.get(tool["name"]):
            case "add":
                return Text("+", style=tone(self.app, "bold $accent"))
            case "remove":
                return Text("−", style=tone(self.app, "bold $error"))
        return Text("✓") if tool.get("selected") else Text("·", style="dim")

    def state_cell(self, tool: dict[str, Any]) -> Text:
        # colour only for problems; everything fine stays neutral
        if tool.get("installed"):
            return Text("installed", style="" if tool.get("selected") else "dim")
        if tool.get("selected"):
            return Text("missing", style=tone(self.app, "bold $error"))
        return Text("—", style="dim")

    def version_cell(self, tool: dict[str, Any]) -> Text:
        pinned, actual = field(tool, "pinned"), field(tool, "actual")
        n = 9 if self.compact else 12
        if actual and pinned and actual != pinned:
            return Text(f"{clip(actual, n)} → {clip(pinned, n)}", style=tone(self.app, "$warning"))
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
            if needle and needle not in f"{t['name']} {group} {source} {field(t, 'about')}".lower():
                continue
            shown += 1
            pinned, actual = field(t, "pinned"), field(t, "actual")
            drift += bool(actual and pinned and actual != pinned)
            missing += bool(t.get("selected") and not t.get("installed"))
            cells = [self.mark_cell(t), clip(t["name"], 22), self.state_cell(t), self.version_cell(t)]
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
        self.render_detail()

    def current(self) -> dict[str, Any] | None:
        table = self.query_one(DataTable)
        if not table.row_count or not table.display:
            return None
        name = str(table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value)
        return next((t for t in self.tools if t["name"] == name), None)

    @on(DataTable.RowHighlighted, "#tool-table")
    def highlighted(self) -> None:
        self.render_detail()

    def render_detail(self) -> None:
        t = self.current()
        detail = self.query_one("#tool-detail", Static)
        if not t:
            detail.update("")
            return
        d = Text()
        d.append(t["name"] + "\n", style="bold")
        d.append((field(t, "about") or "no description") + "\n\n", style="" if field(t, "about") else "dim")
        pinned, actual = field(t, "pinned"), field(t, "actual")
        if t.get("installed"):
            state = Text("installed")
        elif t.get("selected"):
            state = Text("missing · i installs it", style=tone(self.app, "$error"))
        else:
            state = Text("not selected", style="dim")
        rows: list[tuple[str, Text | str]] = [
            ("state", state),
            ("selected", "yes" if t.get("selected") else "no"),
            ("group", field(t, "group")),
            ("source", field(t, "source")),
            ("command", field(t, "bin")),
        ]
        if pinned:
            rows.append(("pinned", pinned))
        if actual:
            off = actual != pinned and bool(pinned)
            rows.append(
                (
                    "installed",
                    Text(actual + ("  ≠ pin" if off else ""), style=tone(self.app, "$warning") if off else ""),
                )
            )
        if field(t, "backend"):
            rows.append(("from", field(t, "backend")))
        for label, value in rows:
            d.append(f"{label:<10}", style="dim")
            d.append(value if isinstance(value, Text) else Text(value))
            d.append("\n")
        mark = self.pending.get(t["name"])
        d.append("\n")
        if mark:
            d.append(f"marked to {mark} · space unmarks · a applies", style=tone(self.app, "$accent"))
        else:
            d.append("space marks it to " + ("remove" if t.get("selected") else "add"), style="dim")
        detail.update(d)

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
            t.append(f"{len(self.pending)} marked, a applies", style=tone(self.app, "bold $accent"))
        self.query_one("#tool-summary", Label).update(t)

    @on(Input.Changed, "#tool-filter")
    def filtered(self) -> None:
        self.render_rows()

    def action_toggle(self) -> None:
        tool = self.current()
        if not tool:
            return
        name = tool["name"]
        if name in self.pending:
            del self.pending[name]
        else:
            self.pending[name] = "remove" if tool.get("selected") else "add"
        # the cursor stays: space again undoes it
        self.render_rows()

    def action_apply(self) -> None:
        if not self.pending:
            self.notify("nothing marked: space marks a tool to add or remove")
            return
        adds = sorted(n for n, v in self.pending.items() if v == "add")
        removes = sorted(n for n, v in self.pending.items() if v == "remove")
        commands = [["add", *adds]] if adds else []
        commands += [["remove", *removes]] if removes else []
        body = Text()
        for verb, names, style in (("add", adds, "$accent"), ("remove", removes, "$error")):
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

    def action_install(self) -> None:
        missing = [t["name"] for t in self.tools if t.get("selected") and not t.get("installed")]
        if not missing:
            self.notify("every selected tool is installed")
            return
        body = Text(f"Install {len(missing)} selected tool(s) at their pins:\n\n", style="bold")
        body.append(", ".join(missing) + "\n\n")
        body.append("Runs the playbook's packages step only: chezmoi and your files are not touched.", style="dim")

        def confirmed(yes: bool | None) -> None:
            if yes:
                self.app.push_screen(Run("Install missing tools", [["install"]]), lambda _rc: self.action_refresh())

        self.app.push_screen(Confirm("Install missing tools", body, yes="Install"), confirmed)


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
    """Is this machine healthy and in sync? A verdict, then what to do."""

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
        self.checked_at = 0.0
        self.show_all = False
        self.doctor_error = ""
        self.details: dict[str, Text] = {}

    def compose(self) -> ComposeResult:
        with Vertical(id="status-box", classes="box"):
            yield Static("", id="verdict")
            yield OptionList(id="attention")
            yield Static("", id="meters")

    def on_mount(self) -> None:
        self.query_one("#status-box").border_title = "Status"
        self.load_state()
        self.render_status()

    # The last check survives restarts: doctor and the fetch are slow, and
    # the result is still useful when it's a few hours old.
    @staticmethod
    def state_file() -> Path:
        base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
        return Path(base) / "dotfiles" / "tui-status.json"

    def save_state(self) -> None:
        state = {
            "time": self.checked_at,
            "doctor": self.doctor,
            "doctor_rc": self.doctor_rc,
            "doctor_error": self.doctor_error,
            "check": self.check,
            "check_rc": self.check_rc,
        }
        with suppress(OSError):
            f = self.state_file()
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps(state))

    def load_state(self) -> None:
        try:
            state = json.loads(self.state_file().read_text())
            doctor = [(str(k), str(t), [str(d) for d in ds]) for k, t, ds in state["doctor"]]
            check = {str(k): [str(x) for x in v] for k, v in (state.get("check") or {}).items()}
            self.doctor, self.check = doctor, check
            self.doctor_rc, self.check_rc = int(state.get("doctor_rc", 0)), int(state.get("check_rc", 0))
            self.doctor_error = str(state.get("doctor_error") or "")
            self.checked_at = float(state["time"])
        except Exception:  # a damaged state file is just no state
            return

    def age(self) -> str:
        if not self.checked_at:
            return ""
        mins = int((time.time() - self.checked_at) // 60)
        if mins < 1:
            return "just now"
        if mins < 60:
            return f"{mins} min ago"
        if mins < 48 * 60:
            return f"{mins // 60} h ago"
        return f"{mins // (24 * 60)} days ago"

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
        self.checked_at = time.time()
        self.save_state()
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

    def items(self) -> list[tuple[str, int, str, str, str, str]]:
        """What needs doing, aggregated: (key, rank, mark, style, text, hint).
        Rank 1-2 need fixing; the rest are things you could do."""
        tools, files = self.app_tools(), self.app_files()
        out: list[tuple[str, int, str, str, str, str]] = []

        def plural(n: int, one: str, many: str) -> str:
            return f"{n} {one if n == 1 else many}"

        doctor = self.doctor or []
        fails = sum(1 for e in doctor if e[0] == "FAIL")
        warns = sum(1 for e in doctor if e[0] == "WARN")
        # one health line: failures and warnings open the same report
        if self.doctor_error:
            out.append(("health", 1, "✗", "$error", "doctor didn't run", "enter shows why"))
        elif fails or warns:
            parts = [f"{fails} failing"] if fails else []
            parts += [plural(warns, "warning", "warnings")] if warns else []
            mark, style, rank = ("✗", "$error", 1) if fails else ("▲", "$warning", 4)
            out.append(("health", rank, mark, style, "health checks: " + ", ".join(parts), "enter"))
        missing = [t for t in tools if t.get("selected") and not t.get("installed")]
        if missing:
            names = ", ".join(t["name"] for t in missing[:3]) + ("…" if len(missing) > 3 else "")
            out.append(
                (
                    "tools-missing",
                    2,
                    "○",
                    "$error",
                    f"{plural(len(missing), 'tool', 'tools')} not installed: {names}",
                    "→ Tools",
                )
            )
        local = [f for f in files if f.get("local")]
        if local:
            out.append(
                (
                    "files-local",
                    3,
                    "●",
                    "$warning",
                    plural(len(local), "file edited here", "files edited here"),
                    "→ Files",
                )
            )
        commits = [c for c in (self.check or {}).get("incoming commits", []) if not c.startswith("(")]
        if commits:
            out.append(
                ("updates", 5, "↓", "$accent", plural(len(commits), "update waiting", "updates waiting"), "u update")
            )
        drift = [
            t for t in tools if field(t, "actual") and field(t, "pinned") and field(t, "actual") != field(t, "pinned")
        ]
        if drift:
            out.append(
                (
                    "tools-drift",
                    6,
                    "→",
                    "$warning",
                    plural(len(drift), "tool off its pin", "tools off their pin"),
                    "→ Tools",
                )
            )
        pending = [f for f in files if f.get("pending") and not f.get("local")]
        if pending:
            out.append(
                (
                    "files-pending",
                    7,
                    "◌",
                    "",
                    plural(len(pending), "file waiting to apply", "files waiting to apply"),
                    "→ Files",
                )
            )
        return sorted(out, key=lambda i: i[1])

    def render_status(self) -> None:
        items = self.items()
        verdict = Text()
        needs_fix = [i for i in items if i[1] <= 2]
        if self.checking:
            verdict.append("◌  Checking…\n", style=tone(self.app, "bold $accent"))
            verdict.append("doctor, then a fetch: nothing changes", style="dim")
        else:
            if needs_fix:
                what = "thing needs" if len(needs_fix) == 1 else "things need"
                verdict.append(f"✗  {len(needs_fix)} {what} fixing\n", style=tone(self.app, "bold $error"))
            elif items:
                n = len(items)
                verdict.append(
                    f"▲  {n} {'thing' if n == 1 else 'things'} you could do\n", style=tone(self.app, "bold $warning")
                )
            else:
                verdict.append("✓  All good\n", style=tone(self.app, "bold $success"))
            if self.checked_at:
                verdict.append(f"health and updates checked {self.age()} · r checks again", style="dim")
            else:
                verdict.append("health and updates not checked yet · r checks (reads and fetches only)", style="dim")
        self.query_one("#verdict", Static).update(verdict)

        attention = self.query_one("#attention", OptionList)
        keep = attention.highlighted
        attention.clear_options()
        width = max(30, self.size.width - 16)
        shown = items if self.show_all or len(items) <= 5 else items[:4]
        for key, _rank, mark, style, text, hint in shown:
            prompt = Table.grid(expand=True, padding=(0, 2))
            prompt.add_column(width=1)
            prompt.add_column(ratio=1, no_wrap=True, overflow="ellipsis")
            prompt.add_column(justify="right", no_wrap=True)
            prompt.add_row(
                Text(mark, style=tone(self.app, style) if style else "dim"), clip(text, width), Text(hint, style="dim")
            )
            attention.add_option(Option(prompt, id=key))
        if len(shown) < len(items):
            attention.add_option(Option(Text(f"  + {len(items) - len(shown)} more", style="dim"), id="more"))
        attention.display = bool(items)
        if items:
            attention.highlighted = min(keep or 0, len(items) - 1)
        self.render_meters()

    def render_meters(self) -> None:
        """One btop-style line: tools as a bar, then health, files, updates."""
        tools, files = self.app_tools(), self.app_files()
        m = Text()
        if tools:
            selected = [t for t in tools if t.get("selected")]
            ok = sum(1 for t in selected if t.get("installed"))
            width = 16
            fill = round(width * ok / len(selected)) if selected else 0
            m.append("tools ", style="dim")
            m.append("█" * fill, style=tone(self.app, "$accent"))
            m.append("░" * (width - fill), style="dim")
            m.append(f" {ok}/{len(selected)}", style="dim")
        if self.doctor:
            n = {k: sum(1 for e in self.doctor if e[0] == k) for k in DOCTOR_MARK}
            m.append("    health ", style="dim")
            m.append(f"✓{n['OK']}", style="dim")
            m.append(f" ▲{n['WARN']}", style=tone(self.app, "$warning") if n["WARN"] else "dim")
            m.append(f" ✗{n['FAIL']}", style=tone(self.app, "$error") if n["FAIL"] else "dim")
        if files:
            local = sum(1 for f in files if f.get("local"))
            m.append(f"    files {local} edited · {len(files) - local} to apply", style="dim")
        self.query_one("#meters", Static).update(m)

    @on(OptionList.OptionSelected, "#attention")
    def open_item(self, event: OptionList.OptionSelected) -> None:
        key = event.option.id or ""
        app = self.app
        if not isinstance(app, DotfilesApp):
            return
        tools = self.app_tools()
        if key == "more":
            self.show_all = True
            self.render_status()
        elif key.startswith("health"):
            app.push_screen(HealthReport(self.doctor or [], self.doctor_error, self.age()))
        elif key == "files-local" or key == "files-pending":
            files = [f for f in self.app_files() if f.get("local") == (key == "files-local")]
            app.action_tab("files")
            app.query_one(FilesPane).select(files[0]["path"] if files else None)
        elif key == "tools-missing":
            first = next((t for t in tools if t.get("selected") and not t.get("installed")), None)
            app.action_tab("tools")
            if first:
                app.query_one(ToolsPane).select(first["name"])
        elif key == "tools-drift":
            first = next((t for t in tools if field(t, "actual") and field(t, "actual") != field(t, "pinned")), None)
            app.action_tab("tools")
            if first:
                app.query_one(ToolsPane).select(first["name"])
        elif key == "updates":
            self.action_update()

    def action_open(self) -> None:
        attention = self.query_one("#attention", OptionList)
        if attention.highlighted is not None:
            attention.action_select()


class HealthReport(ModalScreen[None]):
    """doctor's problems with their details, then a count of what passed."""

    BINDINGS = [Binding("escape,q,enter", "close", "close")]

    def __init__(self, entries: list[tuple[str, str, list[str]]], error: str, age: str) -> None:
        super().__init__()
        self.entries, self.error, self.age = entries, error, age

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog wide") as box:
            box.border_title = "Health" + (f" · checked {self.age}" if self.age else "")
            yield RichLog(id="report", wrap=True, min_width=20, auto_scroll=False)
            yield Label(Text("esc closes · r on Status checks again", style="dim"), id="run-status")

    def on_mount(self) -> None:
        log = self.query_one(RichLog)
        if self.error:
            log.write(Text("doctor didn't run", style=tone(self.app, "bold $error")))
            log.write(Text(self.error, style="dim"))
            return
        problems = sorted((e for e in self.entries if e[0] != "OK"), key=lambda e: e[0] != "FAIL")
        grid = Table.grid(padding=(0, 1))
        grid.add_column(width=1)
        grid.add_column(ratio=1)
        for kind, text, details in problems:
            mark, style = DOCTOR_MARK[kind]
            body = Text(text)
            for d in details:
                body.append("\n" + d, style="dim")
            grid.add_row(Text(mark, style=tone(self.app, style)), body)
        if problems:
            log.write(grid)
        passing = sum(1 for e in self.entries if e[0] == "OK")
        log.write(Text(f"\n✓ {passing} checks passing", style="dim"))

    def action_close(self) -> None:
        self.dismiss(None)


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
            with Vertical(id="files-left", classes="box"):
                yield Input(placeholder="filter files", id="file-filter", classes="filter")
                yield OptionList(id="file-list")
            with Vertical(id="files-right", classes="box side"):
                yield Label("", id="file-head", classes="summary top")
                yield RichLog(id="file-diff", wrap=False, min_width=20, auto_scroll=False)

    def on_mount(self) -> None:
        self.query_one("#file-filter").display = False
        self.query_one("#files-left").border_title = "Files"
        self.query_one("#files-right").border_title = "Diff"
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
    ("personal_git_dirs", "Personal dirs", "comma-separated; a trailing / covers everything beneath"),
    ("signing_key", "Signing key", "SSH .pub that signs personal commits"),
    ("allow_sudo", "Allow sudo", "native package installs may use sudo"),
    ("shared_home", "Shared home", "one $HOME used by several CPU architectures: tools go per-arch"),
]
SWITCHES = ("allow_sudo", "shared_home")


class MachinePane(Pane):
    """This machine's install.sh answers (ansible/local.yml), edited in place:
    enter (or leaving a field) saves it; ctrl+s applies them all."""

    BINDINGS = [
        Binding("ctrl+s", "apply", "apply to this machine"),
        Binding("r", "refresh", "refresh", show=False),
    ]
    main = "#m-git_name"

    def __init__(self) -> None:
        super().__init__("Machine", id="machine")
        self.data: dict[str, Any] = {}
        self.dirty = False
        self.saved: dict[str, str] = {}  # what local.yml holds, per field
        self.save_lock = asyncio.Lock()
        self.shared_changed = False  # tools must move: install after applying

    def compose(self) -> ComposeResult:
        with VerticalScroll(id="machine-box", classes="box"):
            for key, label, hint in MACHINE_FIELDS:
                with Horizontal(classes="field"):
                    yield Label(label, classes="flabel")
                    if key in SWITCHES:
                        yield Switch(id=f"m-{key}")
                    else:
                        yield Input(id=f"m-{key}", placeholder="not set")
                    yield Label(Text(hint, style="dim"), id=f"h-{key}", classes="fhint")
            yield Static("", id="machine-readonly")
        yield Label("", id="machine-summary", classes="summary")

    def on_mount(self) -> None:
        self.query_one("#machine-box").border_title = "Machine · ansible/local.yml"
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
        values = data["values"]
        for key, _label, _hint in MACHINE_FIELDS:
            v = values.get(key)
            if key in SWITCHES:
                with self.prevent(Switch.Changed):
                    self.query_one(f"#m-{key}", Switch).value = bool(v)
                self.saved[key] = "true" if v else "false"
            else:
                shown = self.show(v)
                self.query_one(f"#m-{key}", Input).value = shown
                self.saved[key] = shown
            self.query_one(f"#m-{key}").disabled = not data.get("exists")
        self.render_extras()

    @staticmethod
    def show(value: Any) -> str:
        if value is None:
            return ""
        if isinstance(value, bool):
            return "yes" if value else "no"
        if isinstance(value, list):
            return ", ".join(str(v) for v in value)
        return str(value)

    def render_extras(self) -> None:
        values = self.data.get("values", {})
        key = self.show(values.get("signing_key"))
        hint = self.query_one("#h-signing_key", Label)
        if key:
            ok = (self.data.get("signing") or {}).get("exists")
            hint.update(
                Text(
                    "✓ key file found" if ok else "✗ key file missing", style="dim" if ok else tone(self.app, "$error")
                )
            )
        else:
            hint.update(Text("SSH .pub that signs personal commits", style="dim"))
        groups = values.get("tool_groups")
        sel = self.show(groups) if groups is not None else "every group"
        if values.get("tools_add"):
            sel += f"  +{self.show(values['tools_add'])}"
        if values.get("tools_remove"):
            sel += f"  −{self.show(values['tools_remove'])}"
        ro = Text()
        ro.append(f"{'Tools':<16}", style="bold dim")
        ro.append(f"{clip(sel, 34):<36}")
        ro.append("change in the Tools tab\n", style="dim")
        self.query_one("#machine-readonly", Static).update(ro)
        path = str(self.data.get("path", ""))
        home = os.path.expanduser("~")
        path = "~" + path[len(home) :] if path.startswith(home + "/") else path
        s = Text(clip(path, 60), style="dim")
        if not self.data.get("exists"):
            s = Text("no local.yml yet: run install.sh first", style=tone(self.app, "$error"))
        elif self.dirty:
            s.append(
                "   ● saved to local.yml · ctrl+s applies it to this machine", style=tone(self.app, "bold $warning")
            )
        else:
            s.append("   enter saves a field · ctrl+s applies", style="dim")
        self.query_one("#machine-summary", Label).update(s)

    @on(Input.Submitted)
    def submitted(self, event: Input.Submitted) -> None:
        self.save_field(event.input)

    @on(Input.Blurred)
    def blurred(self, event: Input.Blurred) -> None:
        self.save_field(event.input)

    @on(Switch.Changed, "#m-allow_sudo")
    def sudo(self, event: Switch.Changed) -> None:
        self.save("allow_sudo", "true" if event.value else "false")

    @on(Switch.Changed, "#m-shared_home")
    def shared(self, event: Switch.Changed) -> None:
        # it moves where tools live: confirm, and undo the switch on cancel
        body = Text("Tools, uv and mise data move to per-architecture directories (~/.local/bin-<arch>, …)."
                    if event.value else "Tools, uv and mise data move back to the plain directories.")  # fmt: skip
        body.append("\n\nAfter applying (ctrl+s), reinstall with i in Tools.", style="dim")

        def confirmed(yes: bool | None) -> None:
            if yes:
                self.save("shared_home", "true" if event.value else "false")
            else:
                with self.prevent(Switch.Changed):
                    event.switch.value = not event.value

        self.app.push_screen(Confirm("Change shared home?", body, yes="Change"), confirmed)

    def save_field(self, box: Input) -> None:
        key = (box.id or "")[2:]
        if key in self.saved and box.value.strip() != self.saved[key]:
            self.save(key, box.value.strip())

    @work(group="machine-save")
    async def save(self, key: str, value: str) -> None:
        # one edit of local.yml at a time (a blur and a switch can overlap)
        async with self.save_lock:
            rc, out, err = await capture("machine", "set", key, value, "--no-apply")
        hint = self.query_one(f"#h-{key}", Label)
        if rc:
            msg = (err.strip() or out.strip() or f"exit {rc}").splitlines()[-1].removeprefix("dotfiles machine: ")
            hint.update(Text(f"✗ {msg}", style=tone(self.app, "$error")))
            return
        self.saved[key] = value
        self.dirty = True
        self.shared_changed |= key == "shared_home"
        hint.update(Text("✓ saved", style=tone(self.app, "$success")))
        self.render_extras()

    def action_apply(self) -> None:
        body = Text("Rewrites chezmoi's config from local.yml, then runs chezmoi apply.")
        body.append("\n\nFiles edited here are not overwritten: apply stops and Files lists them.", style="dim")

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
        if rc == 0 and self.shared_changed:
            # new shells look for tools in the other place now: put them there
            self.shared_changed = False
            self.app.push_screen(Run("Install tools for the new layout", [["install"]]), lambda _rc: None)


# ANSI colours 0-15 -> base16 slots (the standard base16 terminal mapping)
ANSI_BASE = [
    "base00", "base08", "base0B", "base0A", "base0D", "base0E", "base0C", "base05",
    "base03", "base08", "base0B", "base0A", "base0D", "base0E", "base0C", "base07",
]  # fmt: skip


def hex_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def recolor(text: Text, src: dict[str, str], dst: dict[str, str]) -> Text:
    """TEXT (fastfetch, coloured for palette SRC) repainted in palette DST:
    exact SRC colours and ANSI 0-15 map to the same base16 slot in DST."""
    rev = {v.lower(): k for k, v in src.items()}

    def swap(color: Color | None) -> Color | None:
        if color is None or color.is_default:
            return None
        if color.type in (ColorType.STANDARD, ColorType.EIGHT_BIT) and color.number is not None and color.number < 16:
            return Color.parse(dst[ANSI_BASE[color.number]])
        if color.triplet is not None and (key := rev.get(color.triplet.hex.lower())):
            return Color.parse(dst[key])
        return color

    out = Text(text.plain, style=Style(color=dst["base05"]))
    for span in text.spans:
        st = span.style if isinstance(span.style, Style) else Style.parse(str(span.style))
        out.stylize(Style(color=swap(st.color), bgcolor=swap(st.bgcolor), bold=st.bold, italic=st.italic),
                    span.start, span.end)  # fmt: skip
    return out


_DESKTOP: list[Any] = []


def desktop() -> Any:
    """A stand-in desktop for glass previews: soft gradient and colour blobs."""
    if not _DESKTOP:
        from PIL import Image, ImageDraw, ImageFilter

        w, h = 160, 100
        img = Image.new("RGB", (w, h))
        px = img.load()
        for y in range(h):
            for x in range(w):
                t = (x / w + y / h) / 2
                px[x, y] = (round(58 + (200 - 58) * t), round(110 + (107 - 110) * t), round(165 + (152 - 165) * t))
        draw = ImageDraw.Draw(img)
        draw.ellipse((20, 10, 75, 60), fill=(244, 194, 107))
        draw.ellipse((95, 45, 150, 95), fill=(91, 192, 190))
        draw.rectangle((0, 70, 60, 100), fill=(40, 44, 60))
        _DESKTOP.append(img.filter(ImageFilter.GaussianBlur(3)))
    return _DESKTOP[0]


def glass_blur(blur: str) -> float:
    """Ghostty's background-blur value as a preview blur radius."""
    return {"false": 0, "macos-glass-clear": 1.5, "macos-glass-regular": 5}.get(blur, 6 if blur.isdigit() else 0)


class Preview(Widget):
    """The terminal start screen (fastfetch + a prompt) painted in a palette,
    over the theme's wallpaper blended as Ghostty does (opacity over base00)."""

    def __init__(self, **kw: Any) -> None:
        super().__init__(**kw)
        self.palette: dict[str, str] | None = None
        self.src: dict[str, str] | None = None
        self.slug = self.active_slug = ""
        self.fetch: list[Text] = []
        self.fetch_small: list[Text] = []
        self.image: Any = None  # PIL image of the wallpaper, or None
        self.wall_opacity = 0.15
        self.glass = (1.0, "false")  # (background opacity, blur) being previewed
        self.footer = Text()
        self._grid: tuple[Any, list[list[str]]] | None = None

    def paint(self, slug: str, palette: dict[str, str], src: dict[str, str] | None, footer: Text) -> None:
        self.slug, self.palette, self.src, self.footer = slug, palette, src, footer
        self.refresh()

    def bg_grid(self, w: int, h: int) -> list[list[str]] | None:
        """Per half-cell background, as Ghostty composes it: the desktop
        (blurred) under base00 at the glass opacity, then the wallpaper at
        its opacity. None when it's plain base00 (opaque, no wallpaper)."""
        if not self.palette or w <= 0 or h <= 0:
            return None
        opacity, blur = self.glass
        if self.image is None and opacity >= 1:
            return None
        base = self.palette["base00"]
        key = (self.image, w, h, base, self.glass)
        if self._grid and self._grid[0] == key:
            return self._grid[1]
        from PIL import Image, ImageFilter, ImageOps

        layer = Image.new("RGB", (w, h * 2), hex_rgb(base))
        if opacity < 1:
            back = ImageOps.fit(desktop(), (w, h * 2))
            if (r := glass_blur(blur)) > 0:
                back = back.filter(ImageFilter.GaussianBlur(r))
            layer = Image.blend(back, layer, opacity)
        if self.image is not None:
            layer = Image.blend(layer, ImageOps.fit(self.image, (w, h * 2)), self.wall_opacity)
        px = layer.load()
        rows = [["#{:02x}{:02x}{:02x}".format(*px[x, y][:3]) for x in range(w)] for y in range(h * 2)]
        self._grid = (key, rows)
        return rows

    def build_lines(self, w: int) -> list[Text]:
        p = self.palette or {}
        out: list[Text] = [Text("")]
        fetch = self.fetch if self.fetch and max(t.cell_len for t in self.fetch) + 2 <= w else self.fetch_small
        if fetch and self.src:
            for t in fetch:
                line = recolor(t, self.src, p)
                if self.active_slug and self.active_slug in line.plain and self.slug != self.active_slug:
                    i = line.plain.index(self.active_slug)
                    line = (
                        line[:i] + Text(self.slug, style=Style(color=p["base05"])) + line[i + len(self.active_slug) :]
                    )
                out.append(Text("  ") + line)
        else:
            # no fastfetch: the palette itself
            for row in (BASES[:8], BASES[8:]):
                t = Text("  ")
                for k in row:
                    t.append("███", style=p[k])
                    t.append(" ")
                out.append(t)
        out.append(Text(""))
        prompt = Text("  ")
        prompt.append("~/workspace/dotfiles", style=Style(color=p["base0D"], bold=True))
        prompt.append(" on ", style=p["base04"])
        prompt.append(" main", style=Style(color=p["base0E"], bold=True))
        prompt.append(" !1", style=p["base0A"])
        out.append(prompt)
        cmd = Text("  ")
        cmd.append("❯ ", style=Style(color=p["base0B"], bold=True))
        cmd.append("git commit -m ", style=p["base05"])
        cmd.append('"look: preview"', style=p["base0B"])
        cmd.append(" ▏", style=p["base05"])
        out.append(cmd)
        return out

    @staticmethod
    def over_wallpaper(row: Text, top: list[str], bottom: list[str]) -> Text:
        """ROW over two wallpaper pixel rows: blank cells become ▀ (top pixel as
        the glyph, bottom as the background); text keeps its colour over the
        bottom pixel."""
        styles = [row.style if isinstance(row.style, Style) else Style()] * len(row.plain)
        for span in row.spans:
            st = span.style if isinstance(span.style, Style) else Style.parse(str(span.style))
            for i in range(span.start, min(span.end, len(styles))):
                styles[i] = styles[i] + st
        out = Text()
        for x, ch in enumerate(row.plain[: len(top)]):
            if ch == " ":
                out.append("▀", Style(color=top[x], bgcolor=bottom[x]))
            else:
                out.append(ch, styles[x] + Style(bgcolor=bottom[x]))
        return out

    def render(self) -> Text:
        w, h = self.size.width, self.size.height
        if not self.palette or w <= 0 or h <= 0:
            return Text("")
        p = self.palette
        content = self.build_lines(w)
        foot = Text("  ") + self.footer
        rows = content[: max(0, h - 2)] + [Text("")] * max(0, h - 2 - len(content)) + [Text(""), foot]
        grid = self.bg_grid(w, h)
        out = Text()
        for y, row in enumerate(rows[:h]):
            row = row[:w]
            row.pad_right(w - row.cell_len)
            if grid is None:
                row.stylize(Style(bgcolor=p["base00"]), 0, len(row))
                out.append(row)
            else:
                out.append(self.over_wallpaper(row, grid[2 * y], grid[2 * y + 1]))
            if y < h - 1:
                out.append("\n")
        return out


class LookPane(Pane):
    """Themes, glass and wallpaper, with the start screen previewed in each."""

    BINDINGS = [
        Binding("slash", "filter", "filter"),
        Binding("w", "wallpaper", "wallpaper preview"),
        Binding("W", "apply_wallpaper", "apply wallpaper"),
        Binding("g", "glass", "glass"),
        Binding("t", "themes", "themes", show=False),
        Binding("r", "refresh", "refresh"),
        Binding("escape", "clear_filter", "clear", show=False),
    ]
    main = "#theme-list"
    filter_id = "#theme-filter"

    def __init__(self) -> None:
        super().__init__("Look", id="look")
        self.look: dict[str, Any] = {}
        self.wall_preview: bool | None = None  # None: follow the machine's setting
        self.glass_preview: str | None = None  # a glass level being previewed
        self.images: dict[str, Any] = {}

    def compose(self) -> ComposeResult:
        with Horizontal():
            with Vertical(id="look-left"):
                with Vertical(id="themes-box", classes="box"):
                    yield Input(placeholder="filter themes", id="theme-filter", classes="filter")
                    yield OptionList(id="theme-list")
                with Vertical(id="glass-box", classes="box"):
                    yield OptionList(id="glass-list")
            with Vertical(id="preview-box", classes="box side"):
                yield Preview(id="preview")

    def on_mount(self) -> None:
        self.query_one("#theme-filter").display = False
        self.query_one("#themes-box").border_title = "Themes"
        self.query_one("#glass-box").border_title = "Glass · g"
        self.query_one("#preview-box").border_title = "Preview"
        self.action_refresh()
        self.load_fetch()

    def action_glass(self) -> None:
        self.query_one("#glass-list", OptionList).focus()

    def action_themes(self) -> None:
        self.focus_main()

    @work(group="fetch")
    async def load_fetch(self) -> None:
        """The real start screen, once per launch (fastfetch only reads)."""
        preview = self.query_one(Preview)
        for args, attr in ((["look", "--fetch"], "fetch"), (["look", "--fetch", "--no-logo"], "fetch_small")):
            rc, out, _ = await capture(*args)
            lines = [Text.from_ansi(s) for s in out.rstrip("\n").split("\n")] if rc == 0 and out.strip() else []
            setattr(preview, attr, lines)
        self.render_preview()

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
            self.notify(f"dotfiles look failed: {e}", severity="error")
            return
        self.look = look
        preview = self.query_one(Preview)
        preview.active_slug = field(look, "theme")
        preview.src = self.palette(preview.active_slug)
        if isinstance(look.get("wallpaper_opacity"), int | float):
            preview.wall_opacity = float(look["wallpaper_opacity"])
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
            self.app.apply_palette(preview.src)
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
            self.notify(f"no themes match “{needle}”")

    @on(Input.Changed, "#theme-filter")
    def filtered(self) -> None:
        self.render_themes()

    def highlighted_slug(self) -> str:
        themes = self.query_one("#theme-list", OptionList)
        if themes.highlighted is None or not themes.option_count:
            return field(self.look, "theme")
        return str(themes.get_option_at_index(themes.highlighted).id)

    def wall_on(self) -> bool:
        if self.wall_preview is not None:
            return self.wall_preview
        return (field(self.look, "wallpaper") or "on") != "off"  # absent = on, as the template

    @on(OptionList.OptionHighlighted, "#theme-list")
    def preview_theme(self) -> None:
        self.render_preview()
        self.load_image(self.highlighted_slug())

    @work(exclusive=True, group="image", thread=True)
    def load_image(self, slug: str) -> None:
        path = (self.look.get("wallpapers") or {}).get(slug)
        img = None
        if isinstance(path, str) and self.wall_on():
            img = self.images.get(path)
            if img is None:
                try:
                    from PIL import Image

                    with Image.open(path) as im:
                        im.thumbnail((640, 640))
                        img = im.convert("RGB")
                    self.images[path] = img
                except Exception:  # any unreadable image: no wallpaper preview
                    img = None
        self.app.call_from_thread(self.set_image, slug, img)

    def set_image(self, slug: str, img: Any) -> None:
        if slug == self.highlighted_slug():
            self.query_one(Preview).image = img
            self.render_preview()

    def render_preview(self) -> None:
        slug = self.highlighted_slug()
        palette = self.palette(slug)
        preview = self.query_one(Preview)
        if not palette:
            preview.palette = None
            preview.refresh()
            return
        has_wall = slug in (self.look.get("wallpapers") or {})
        on = self.wall_on()
        if not (has_wall and on):
            preview.image = None
        levels = self.look.get("glass_levels") or {}
        level = levels.get(self.glass_level()) or {}
        try:
            preview.glass = (float(level.get("opacity", 1)), str(level.get("blur", "false")))
        except (TypeError, ValueError):
            preview.glass = (1.0, "false")
        dim, fg = palette["base03"], palette["base05"]
        f = Text()
        f.append(slug, style=Style(color=fg, bold=True))
        active = slug == field(self.look, "theme")
        f.append("  ● active" if active else "  enter applies", style=dim)
        f.append("  ·  wallpaper ", style=dim)
        if not has_wall:
            f.append("none for this theme", style=dim)
        else:
            f.append("on" if on else "off", style=Style(color=palette["base0B"] if on else dim, bold=True))
            machine = (field(self.look, "wallpaper") or "on") != "off"
            f.append("  w previews" + ("  W applies" if on != machine else ""), style=dim)
        f.append("  ·  glass ", style=dim)
        f.append(self.glass_level(), style=Style(color=fg, bold=True))
        if self.glass_preview and self.glass_preview != (field(self.look, "glass") or "default"):
            f.append("  enter applies", style=dim)
        preview.paint(slug, palette, preview.src, f)

    def action_wallpaper(self) -> None:
        self.wall_preview = not self.wall_on()
        self.render_preview()
        self.load_image(self.highlighted_slug())

    def action_apply_wallpaper(self) -> None:
        mode = "on" if self.wall_on() else "off"
        if mode == (field(self.look, "wallpaper") or "on"):
            self.notify(f"wallpaper is already {mode}")
            return
        self.app.push_screen(Run(f"wallpaper {mode}", [["wallpaper", mode]]), self.applied)

    @on(OptionList.OptionSelected, "#theme-list")
    def pick_theme(self, event: OptionList.OptionSelected) -> None:
        if slug := event.option.id:
            self.app.push_screen(Run(f"theme {slug}", [["theme", slug]]), self.applied)

    @on(OptionList.OptionHighlighted, "#glass-list")
    def preview_glass(self, event: OptionList.OptionHighlighted) -> None:
        if self.query_one("#glass-list").has_focus:
            self.glass_preview = event.option.id
            self.render_preview()

    def glass_level(self) -> str:
        return self.glass_preview or field(self.look, "glass") or "default"

    @on(OptionList.OptionSelected, "#glass-list")
    def pick_glass(self, event: OptionList.OptionSelected) -> None:
        if level := event.option.id:
            self.app.push_screen(Run(f"glass {level}", [["glass", level]]), self.applied)

    def applied(self, _rc: int | None) -> None:
        self.wall_preview = None
        self.glass_preview = None
        self.action_refresh()
        self.load_fetch()  # the splash is re-rendered with the new theme's colours
        if isinstance(self.app, DotfilesApp):
            self.app.query_one(FilesPane).action_refresh()
            self.app.query_one(PromptPane).action_refresh()  # its swatches and background


class PromptPreview(Widget):
    """The real prompt (`dotfiles prompt --preview`: starship with the chosen
    options) on the active theme's background: after a command that worked,
    then after a slow one that failed, with the cursor in the chosen shape."""

    OUTPUT = "README.md  ansible  home  scripts  site  tests"

    def __init__(self, **kw: Any) -> None:
        super().__init__(**kw)
        self.data: dict[str, Any] | None = None
        self.bg = self.fg = ""  # the active theme's base00 / base05, once known
        self.cursor = "bar"
        self.message = "rendering…"
        self.footer = Text()

    @staticmethod
    def prompt(part: Any, width: int, typed: Text) -> list[Text]:
        """PART's left prompt lines, TYPED after the symbol, and its right
        prompt on the last line's right edge, as zsh draws RPROMPT."""
        left = part.get("left") if isinstance(part, dict) else None
        right = part.get("right") if isinstance(part, dict) else None
        lines = Text.from_ansi(left if isinstance(left, str) else "").split("\n", allow_blank=True)
        if not lines:
            lines = [Text("")]
        last = lines[-1] + typed
        if isinstance(right, str) and right.strip():
            r = Text.from_ansi(right)
            if (gap := width - last.cell_len - r.cell_len) >= 1:
                last = last + Text(" " * gap) + r
        lines[-1] = last
        return lines

    def caret(self) -> Text:
        fg = self.fg or "white"
        if self.cursor == "block":
            return Text(" ", style=Style(bgcolor=fg))
        return Text("▁" if self.cursor == "underline" else "▏", style=fg)

    def render(self) -> Text:
        w, h = self.size.width, self.size.height
        if w <= 0 or h <= 0:
            return Text("")
        rows: list[Text] = []
        if self.data:
            rows += self.prompt(self.data.get("ok"), w - 2, Text("ls", style=self.fg))
            rows.append(Text(self.OUTPUT, style=self.fg))
            rows += self.prompt(self.data.get("err"), w - 2, self.caret())
        else:
            rows.append(Text(self.message, style="dim"))
        body = [Text(" ") + r for r in rows]
        foot = Text(" ") + self.footer
        lines = body[: max(0, h - 2)] + [Text("")] * max(0, h - 2 - len(body)) + [Text(""), foot]
        out = Text()
        for y, row in enumerate(lines[:h]):
            row.truncate(w, overflow="crop")
            row.pad_right(w - row.cell_len)
            if self.bg:
                # under the prompt's own colours: rainbow blocks keep theirs
                row.stylize_before(Style(bgcolor=self.bg), 0, len(row))
            out.append(row)
            if y < h - 1:
                out.append("\n")
        return out


class PromptPane(Pane):
    """The prompt (starship) and the cursor: every option, changed with ←/→
    and previewed with the real prompt before enter applies them."""

    BINDINGS = [
        Binding("left,h", "cycle(-1)", "change", show=False),
        Binding("right,l,space", "cycle(1)", "change", key_display="←→"),
        Binding("escape", "revert", "revert"),
        Binding("d", "defaults", "defaults"),
        Binding("r", "refresh", "refresh"),
    ]
    main = "#prompt-list"

    def __init__(self) -> None:
        super().__init__("Prompt", id="prompt")
        self.options: list[dict[str, Any]] = []
        self.values: dict[str, str] = {}  # this machine's
        self.pending: dict[str, str] = {}  # changed here, not applied yet
        self.swatches: dict[str, str] = {}  # colour name -> #rrggbb

    def compose(self) -> ComposeResult:
        with Horizontal():
            with Vertical(id="prompt-left", classes="box"):
                yield OptionList(id="prompt-list")
                yield Static("", id="prompt-about")
            with Vertical(id="prompt-preview-box", classes="box side"):
                yield PromptPreview(id="prompt-preview")

    def on_mount(self) -> None:
        self.query_one("#prompt-left").border_title = "Prompt"
        self.query_one("#prompt-preview-box").border_title = "Preview"
        self.action_refresh()

    def on_resize(self) -> None:
        # also when the tab first shows: the preview is drawn for its width
        if self.options:
            self.load_preview()

    @staticmethod
    def valid(o: Any) -> bool:
        if not isinstance(o, dict) or not all(isinstance(o.get(k), str) for k in ("key", "label", "default")):
            return False
        choices = o.get("choices")
        return isinstance(choices, list) and all(isinstance(c, str) for c in choices) and o["default"] in choices

    @work(exclusive=True, group="prompt")
    async def action_refresh(self) -> None:
        rc, out, err = await capture("prompt", "--json")
        try:
            if rc:
                raise ValueError(err.strip() or f"exit {rc}")
            data = json.loads(out)
            if not isinstance(data, dict):
                raise ValueError("not an object")
        except (ValueError, json.JSONDecodeError) as e:
            self.notify(f"dotfiles prompt failed: {e}", severity="error")
            preview = self.query_one(PromptPreview)
            preview.message = f"no prompt options: {e}"
            preview.refresh()
            return
        options = data.get("options")
        self.options = [o for o in options if self.valid(o)] if isinstance(options, list) else []
        values = data.get("values") if isinstance(data.get("values"), dict) else {}
        self.values = {
            o["key"]: v if (v := values.get(o["key"])) in o["choices"] else o["default"] for o in self.options
        }
        palette = data.get("palette") if isinstance(data.get("palette"), dict) else {}
        self.swatches = {k: v for k, v in palette.items() if isinstance(v, str) and HEX.fullmatch(v)}
        self.pending = {k: v for k, v in self.pending.items() if k in self.values and v != self.values[k]}
        self.render_list()
        self.load_preview()

    def effective(self) -> dict[str, str]:
        return {**self.values, **self.pending}

    @staticmethod
    def not_applicable(key: str, eff: dict[str, str]) -> str:
        """Why KEY does nothing with EFF's other choices, else ""."""
        if key in ("separator", "start", "right_ends") and eff.get("style") not in ("rainbow", "bar"):
            return "rainbow or bar only"
        if key == "bar_color" and eff.get("style") != "bar":
            return "bar style only"
        if key == "frame" and eff.get("lines") != "two":
            return "two lines only"
        split2 = eff.get("lines") == "two" and eff.get("layout") == "split"
        if key == "fill" and not split2:
            return "two-line split only"
        framed = eff.get("lines") == "two" and eff.get("frame") == "on"
        if key == "frame_color" and not framed and not (split2 and eff.get("fill") != "space"):
            return "no frame or fill"
        return ""

    def option(self, key: str | None) -> dict[str, Any] | None:
        return next((o for o in self.options if o["key"] == key), None)

    def highlighted(self) -> dict[str, Any] | None:
        ol = self.query_one("#prompt-list", OptionList)
        if ol.highlighted is None or not ol.option_count:
            return None
        return self.option(ol.get_option_at_index(ol.highlighted).id)

    def render_list(self) -> None:
        ol = self.query_one("#prompt-list", OptionList)
        keep = ol.highlighted
        eff = self.effective()
        ol.clear_options()
        for o in self.options:
            key, value = o["key"], eff[o["key"]]
            na = self.not_applicable(key, eff)
            row = Text()
            row.append(f"{o['label']:<17}", style="dim" if na else "")
            if key.endswith("_color") and (hexv := self.swatches.get(value)):
                row.append("██ ", style=hexv)
            if key in self.pending:
                row.append(value, style=tone(self.app, "bold $accent"))
                row.append(" •", style=tone(self.app, "$warning"))
            else:
                row.append(value, style="dim" if na else "bold")
            if na:
                row.append(f"  {na}", style="dim italic")
            ol.add_option(Option(row, id=key))
        if ol.option_count:
            ol.highlighted = min(keep or 0, ol.option_count - 1)
        self.render_about()

    def render_about(self) -> None:
        o = self.highlighted()
        about = Text()
        if o:
            value = self.effective()[o["key"]]
            for i, choice in enumerate(o["choices"]):
                if i:
                    about.append(" · ", style="dim")
                about.append(choice, style=tone(self.app, "bold $accent") if choice == value else "dim")
            about.append("\n")
            about.append(str(o.get("about") or ""), style="dim")
        self.query_one("#prompt-about", Static).update(about)

    @on(OptionList.OptionHighlighted, "#prompt-list")
    def moved(self) -> None:
        self.render_about()

    def changed(self) -> None:
        self.render_list()
        self.load_preview()

    def action_cycle(self, step: int) -> None:
        if not (o := self.highlighted()):
            return
        key, choices = o["key"], o["choices"]
        new = choices[(choices.index(self.effective()[key]) + step) % len(choices)]
        if new == self.values[key]:
            self.pending.pop(key, None)
        else:
            self.pending[key] = new
        self.changed()

    def action_revert(self) -> None:
        if self.pending:
            self.pending.clear()
            self.changed()

    def action_defaults(self) -> None:
        self.pending = {o["key"]: o["default"] for o in self.options if o["default"] != self.values[o["key"]]}
        self.changed()

    @on(OptionList.OptionSelected, "#prompt-list")
    def apply(self) -> None:
        if not self.pending:
            self.notify("nothing to apply: ←/→ change the highlighted option")
            return
        pairs = [f"{k}={v}" for k, v in self.pending.items()]
        self.app.push_screen(Run("prompt " + " ".join(pairs), [["prompt", *pairs]]), self.applied)

    def applied(self, rc: int | None) -> None:
        if rc == 0:
            self.pending.clear()
        self.action_refresh()
        if isinstance(self.app, DotfilesApp):
            self.app.query_one(FilesPane).action_refresh()

    def footer(self) -> Text:
        f = Text()
        if self.pending:
            n = len(self.pending)
            f.append(f"{n} change{'s' if n > 1 else ''}", style=tone(self.app, "bold $warning"))
            f.append("  enter applies  esc reverts", style="dim")
        else:
            f.append("as on this machine", style="dim")
            f.append("  ←/→ change the highlighted option  d defaults", style="dim")
        eff = self.effective()
        if eff.get("blink") == "on":
            f.append("  ·  the cursor blinks", style="dim")
        return f

    @work(exclusive=True, group="prompt-preview")
    async def load_preview(self) -> None:
        await asyncio.sleep(0.15)  # a burst of ←/→ renders once
        preview = self.query_one(PromptPreview)
        eff = self.effective()
        width = max(20, (preview.size.width or 80) - 2)
        pairs = [f"{k}={v}" for k, v in eff.items()]
        rc, out, err = await capture("prompt", "--preview", "--width", str(width), *pairs)
        try:
            if rc:
                raise ValueError(err.strip() or f"exit {rc}")
            data = json.loads(out)
            if not isinstance(data, dict):
                raise ValueError("not an object")
        except (ValueError, json.JSONDecodeError) as e:
            preview.data = None
            preview.message = f"preview failed: {e}"
        else:
            preview.data = data
        preview.bg, preview.fg = self.swatches.get("bg", ""), self.swatches.get("text", "")
        preview.cursor = eff.get("cursor", "bar")
        preview.footer = self.footer()
        preview.refresh()


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

    .box { border: round $surface-lighten-2; border-title-color: $text-muted; border-title-style: bold;
      padding: 0 1; background: $background; }
    .box:focus-within { border: round $accent; border-title-color: $accent; }

    .filter { height: 1; border: none; padding: 0 1; background: $surface; }
    .filter:focus { border: none; background-tint: $accent 10%; }
    DataTable { height: 1fr; background: $background; scrollbar-size-vertical: 1; }
    DataTable > .datatable--header { background: $background; color: $text-muted; text-style: bold; }
    DataTable > .datatable--cursor { background: $accent 20%; }
    DataTable:focus > .datatable--cursor { background: $accent 30%; }
    OptionList { border: none; background: $background; scrollbar-size-vertical: 1; }
    OptionList > .option-list--option-highlighted { background: $accent 20%; }
    OptionList:focus > .option-list--option-highlighted { background: $accent 30%; }
    .empty { height: 1fr; content-align: center middle; color: $text; }
    .summary { height: 1; width: 1fr; padding: 0 1; text-wrap: nowrap; text-overflow: ellipsis; color: $text-muted; }
    .summary.top { padding: 1 0 0 0; height: 3; }
    RichLog { height: 1fr; background: $background; scrollbar-size-vertical: 1; }

    #tools-box { width: 1fr; }
    #tool-detail-box { width: 44; }
    #tool-detail { padding: 1 1; }

    #status-box { height: 1fr; }
    #verdict { height: auto; padding: 1 2; }
    #attention { height: auto; max-height: 12; padding: 0 1; }
    #meters { dock: bottom; height: 1; padding: 0 2; }

    #files-left { width: 45%; max-width: 64; }
    #files-right { width: 1fr; }

    #look-left { width: 46; }
    #themes-box { height: 1fr; }
    #theme-list > .option-list--option { padding: 0 0 0 1; }
    #glass-box { height: auto; }
    #glass-list { height: auto; max-height: 6; }
    #preview-box { width: 1fr; padding: 0; }
    #preview { width: 1fr; height: 1fr; }

    #prompt-left { width: 54; }
    #prompt-list { height: 1fr; }
    #prompt-about { height: auto; padding: 1 1 0 1; }
    #prompt-preview-box { width: 1fr; padding: 0; }
    #prompt-preview { width: 1fr; height: 1fr; }

    #machine-box { height: 1fr; }
    .field { height: 2; }
    .flabel { width: 18; text-style: bold; color: $text-muted; }
    .field Input { width: 46; height: 1; border: none; padding: 0 1; background: $surface; }
    .field Input:focus { background-tint: $accent 15%; }
    .field Switch { width: 8; height: 1; border: none; padding: 0; background: $background; }
    .field Switch:focus { background: $accent 35%; }
    .field Switch:focus > .switch--slider { color: $accent; }
    .field:focus-within { background: $accent 12%; }
    .field:focus-within .flabel { color: $accent; }
    .fhint { width: 1fr; padding: 0 0 0 2; }
    #machine-readonly { padding: 1 0 0 0; }

    .title { text-style: bold; color: $accent; margin: 1 0 0 0; }
    Confirm, Run, HealthReport { align: center middle; background: $background 60%; }
    .dialog { width: 70; max-width: 95%; height: auto; padding: 1 2; border: round $accent;
      border-title-color: $accent; border-title-style: bold; background: $surface; }
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
        Binding("5", "tab('prompt')", "prompt", show=False),
        Binding("6", "tab('machine')", "machine", show=False),
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
            yield PromptPane()
            yield MachinePane()
        yield Footer()

    @staticmethod
    def prefs_file() -> Path:
        base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
        return Path(base) / "dotfiles" / "tui.json"

    def __init__(self) -> None:
        super().__init__()
        # the last palette, so the first frame is already in the active theme
        # (look --json, which has the real one, takes a moment)
        with suppress(OSError, ValueError, AttributeError, TypeError, KeyError):
            colors = json.loads(self.prefs_file().read_text())["palette"]
            if all(isinstance(colors.get(k), str) and HEX.fullmatch(colors[k]) for k in BASES):
                self.register_theme(base16_theme(colors))
                self.theme = "dotfiles"

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
        self.query_one(PromptPane).action_refresh()
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
            right.append("1-6 tabs", style="dim")
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
        with suppress(OSError):
            f = self.prefs_file()
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps({"palette": colors}))

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
        # already inside it (a key like g ran before this event): stay there
        if self.focused is not None and event.pane in self.focused.ancestors_with_self:
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
        print("usage: dotfiles tui  (keys: 1-6 tabs, q quit; each tab lists its own)")
        return 0
    DotfilesApp().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
