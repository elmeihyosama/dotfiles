# /// script
# requires-python = ">=3.13"
# dependencies = [
#   "textual==8.2.8",
#   "pillow==12.3.0",
#   "pytest==9.1.1",
#   "pytest-asyncio==1.4.0",
#   "ruff==0.16.10",
# ]
# ///
"""TUI tests (Textual's headless pilot against a stub CLI), plus ruff.

Run: uv run --locked --script tests/tui/test_tui.py (tests/tui.test.sh does).
"""

from __future__ import annotations

import asyncio
import faulthandler
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "scripts" / "tui"))

import dotfiles_tui as tui  # noqa: E402
import palettes as stub  # noqa: E402
from textual.widgets import DataTable, Input, Label, OptionList, RichLog  # noqa: E402

SIZE = (120, 40)


@pytest.fixture
def calls(tmp_path, monkeypatch):
    """Point the TUI at the stub; return a reader for the recorded argvs."""
    log = tmp_path / "calls.jsonl"
    log.touch()
    monkeypatch.setenv("STUB_LOG", str(log))
    monkeypatch.setenv("DOTFILES_CMD", f"{sys.executable} {HERE / 'stub_dotfiles.py'}")
    # the saved Status check: never the real one
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    for var in ("STUB_FAIL", "STUB_LIST", "STUB_THEME", "STUB_PROC", "STUB_SLOW", "STUB_BIG"):
        monkeypatch.delenv(var, raising=False)
    return lambda: [json.loads(x) for x in log.read_text().splitlines()]


async def settle(pilot) -> None:
    await pilot.app.workers.wait_for_complete()
    await pilot.pause()


def text(widget) -> str:
    """The plain text a Label/Static shows."""
    return str(widget.render())


def log_text(log: RichLog) -> str:
    return "\n".join(line.text for line in log.lines)


async def tools(pilot) -> DataTable:
    """Open the Tools tab; return its table (focused)."""
    await settle(pilot)
    await pilot.press("2")
    await settle(pilot)
    return pilot.app.query_one("#tool-table", DataTable)


async def test_tools_table_shows_catalog_and_drift(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        table = await tools(pilot)
        assert table.row_count == 4
        assert [str(k.value) for k in table.rows] == ["fzf", "ripgrep", "lazygit", "zellij"]
        assert [str(c.value) for c in table.columns] == ["mark", "name", "state", "version"]
        assert str(table.get_cell("ripgrep", "version")) == "14.0.0 → 15.1.0"
        assert str(table.get_cell("zellij", "state")) == "missing"
        summary = text(pilot.app.query_one("#tool-summary", Label))
        assert "4 tools" in summary and "1 off pin" in summary and "1 missing" in summary
        detail = text(pilot.app.query_one("#tool-detail"))
        assert "fzf" in detail and "space marks it to remove" in detail


async def test_filter_narrows_rows(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        table = await tools(pilot)
        await pilot.press("slash", *"git")
        await pilot.pause()
        assert [str(k.value) for k in table.rows] == ["lazygit"]
        assert pilot.app.focused is pilot.app.query_one("#tool-filter", Input)


async def test_marks_apply_add_and_remove_after_confirm(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        table = await tools(pilot)
        # space marks without moving: twice is undo
        await pilot.press("space", "space")
        await pilot.pause()
        assert str(table.get_cell("fzf", "mark")) == "✓"
        # fzf (selected) -> remove; lazygit (unselected) -> add
        await pilot.press("space", "down", "down", "space")
        await pilot.pause()
        assert str(table.get_cell("fzf", "mark")) == "−"
        assert str(table.get_cell("lazygit", "mark")) == "+"
        assert "marked to add" in text(pilot.app.query_one("#tool-detail"))
        await pilot.press("a")
        await pilot.pause()
        await pilot.press("y")
        await settle(pilot)
        assert ["add", "lazygit"] in calls()
        assert ["remove", "fzf"] in calls()
        await pilot.press("escape")
        await settle(pilot)
        assert "marked" not in text(pilot.app.query_one("#tool-summary", Label))
        assert calls().count(["list", "--json"]) == 2


async def test_apply_declined_runs_nothing(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await tools(pilot)
        await pilot.press("space", "a")
        await pilot.pause()
        await pilot.press("n")
        await settle(pilot)
        assert not [c for c in calls() if c[0] in ("add", "remove")]


async def test_failed_apply_keeps_marks(calls, monkeypatch):
    monkeypatch.setenv("STUB_FAIL", "remove")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await tools(pilot)
        await pilot.press("space", "a")
        await pilot.pause()
        await pilot.press("y")
        await settle(pilot)
        assert "failed (exit 1)" in text(pilot.app.screen.query_one("#run-status", Label))
        await pilot.press("escape")
        await settle(pilot)
        assert "1 marked" in text(pilot.app.query_one("#tool-summary", Label))


async def test_bad_list_output_shows_error(calls, monkeypatch):
    monkeypatch.setenv("STUB_LIST", "not json")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        table = await tools(pilot)
        assert table.row_count == 0
        assert "dotfiles list failed" in text(pilot.app.query_one("#tool-empty"))


def verdict(pilot) -> str:
    return text(pilot.app.query_one("#verdict"))


def attention(pilot) -> list[str]:
    return [str(o.id) for o in pilot.app.query_one("#attention", OptionList).options]


async def test_status_is_the_default_and_shows_local_state_before_any_check(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        assert pilot.app.query_one(tui.TabbedContent).active == "status"
        assert "not checked yet" in verdict(pilot)
        assert "1 thing needs fixing" in verdict(pilot)  # the missing tool
        assert attention(pilot) == ["tools-missing", "files-local", "tools-drift", "files-pending"]
        assert not [c for c in calls() if c[0] in ("doctor", "update")], "nothing runs until r"


async def test_status_r_checks_and_folds_the_rest(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("r")
        await settle(pilot)
        assert ["doctor"] in calls() and ["update", "--check"] in calls()
        assert "2 things need fixing" in verdict(pilot) and "checked just now" in verdict(pilot)
        # top four, then the rest folded behind "more"
        assert attention(pilot) == ["health-fail", "tools-missing", "files-local", "health-warn", "more"]
        pilot.app.query_one("#attention", OptionList).highlighted = 4
        await pilot.press("enter")
        await pilot.pause()
        assert attention(pilot)[4:] == ["updates", "tools-drift", "files-pending"]
        meters = text(pilot.app.query_one("#meters"))
        assert "tools" in meters and "▲1" in meters and "✗1" in meters


async def test_status_health_item_opens_the_report(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("r")
        await settle(pilot)
        await pilot.press("enter")  # health-fail
        await pilot.pause()
        assert isinstance(pilot.app.screen, tui.HealthReport)
        report = log_text(pilot.app.screen.query_one("#report", RichLog))
        assert report.index("zellij missing") < report.index("fzf also installed")
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(pilot.app.screen, tui.HealthReport)


async def test_status_enter_opens_the_file_or_tool(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        attn = pilot.app.query_one("#attention", OptionList)
        attn.highlighted = attention(pilot).index("files-local")
        await pilot.press("enter")
        await settle(pilot)
        assert pilot.app.query_one(tui.TabbedContent).active == "files"
        lst = pilot.app.query_one("#file-list", OptionList)
        assert lst.get_option_at_index(lst.highlighted).id == ".config/ghostty/config"
        await pilot.press("1")
        await pilot.pause()
        attn.highlighted = attention(pilot).index("tools-drift")
        await pilot.press("enter")
        await settle(pilot)
        assert pilot.app.query_one(tui.TabbedContent).active == "tools"
        assert pilot.app.query_one("#tool-table", DataTable).cursor_row == 1  # ripgrep


async def test_status_update_warns_about_local_edits_then_rechecks(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("u")
        await pilot.pause()
        assert "2 file(s) changed here would be overwritten" in text(pilot.app.screen.query_one(".body"))
        await pilot.press("y")
        await settle(pilot)
        assert ["update"] in calls()
        await pilot.press("escape")
        await settle(pilot)
        assert calls().count(["doctor"]) == 1 and calls().count(["update", "--check"]) == 1


def files_list(pilot) -> OptionList:
    return pilot.app.query_one("#file-list", OptionList)


def current_file(pilot) -> str:
    lst = files_list(pilot)
    return str(lst.get_option_at_index(lst.highlighted).id)


async def test_files_groups_and_diff_preview(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("3")
        await settle(pilot)
        ids = [o.id for o in files_list(pilot).options]
        assert ids == [None, ".config/ghostty/config", ".gitconfig.local", None, ".config/nvim/init.lua"]
        assert current_file(pilot) == ".config/ghostty/config"
        await pilot.pause(0.3)
        await settle(pilot)
        assert ["files", "diff", ".config/ghostty/config"] in calls()
        assert "+background-opacity = 0.66" in log_text(pilot.app.query_one("#file-diff", RichLog))


async def test_files_discard_needs_confirm_and_keep_refuses_templates(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("3")
        await settle(pilot)
        await pilot.press("k")  # ghostty config is a template
        await pilot.pause()
        assert not [c for c in calls() if c[:2] == ["files", "keep"]]
        await pilot.press("a")
        await pilot.pause()
        assert isinstance(pilot.app.screen, tui.Confirm)
        await pilot.press("y")
        await settle(pilot)
        assert ["files", "apply", ".config/ghostty/config"] in calls()
        await pilot.press("escape")
        await settle(pilot)
        await pilot.press("down", "k")
        await pilot.pause()
        await pilot.press("y")
        await settle(pilot)
        assert ["files", "keep", ".gitconfig.local"] in calls()


async def test_files_apply_all_skips_local_edits(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("3")
        await settle(pilot)
        await pilot.press("A")
        await pilot.pause()
        await pilot.press("y")
        await settle(pilot)
        assert ["files", "apply", ".config/nvim/init.lua"] in calls()


async def machine(pilot) -> None:
    await settle(pilot)
    await pilot.press("5")
    await settle(pilot)


async def test_machine_edits_in_place(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await machine(pilot)
        name = pilot.app.query_one("#m-git_name", Input)
        assert name.value == "Aleksandra Wiśniewska-Kowalczyk"
        assert pilot.app.focused is name
        assert pilot.app.query_one("#m-personal_git_name", Input).value == ""
        assert "key file missing" in text(pilot.app.query_one("#h-signing_key"))
        name.value = "Ola"
        await pilot.press("enter")
        await settle(pilot)
        assert ["machine", "set", "git_name", "Ola", "--no-apply"] in calls()
        assert "saved" in text(pilot.app.query_one("#h-git_name"))
        assert "ctrl+s applies" in text(pilot.app.query_one("#machine-summary"))
        # leaving an unchanged field saves nothing
        before = len(calls())
        await pilot.press("tab")
        await settle(pilot)
        assert len(calls()) == before
        await pilot.press("ctrl+s")
        await pilot.pause()
        await pilot.press("y")
        await settle(pilot)
        assert ["machine", "apply"] in calls()


async def test_machine_shows_refusals_inline(calls, monkeypatch):
    monkeypatch.setenv("STUB_FAIL", "machine")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("5")
        await settle(pilot)
        # machine --json failed too (STUB_FAIL covers the subcommand): no crash, an error line
        assert "dotfiles machine failed" in text(pilot.app.query_one("#machine-summary"))


async def test_machine_sudo_switch_saves(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await machine(pilot)
        switch = pilot.app.query_one("#m-allow_sudo", tui.Switch)
        assert switch.value is True
        switch.value = False
        await settle(pilot)
        assert ["machine", "set", "allow_sudo", "false", "--no-apply"] in calls()


async def test_look_previews_the_start_screen_in_each_theme(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("4")
        await settle(pilot)
        themes = pilot.app.query_one("#theme-list", OptionList)
        assert [o.id for o in themes.options] == ["dark-one", "light-two", "bad-hex"]  # "junk" dropped
        preview = pilot.app.query_one(tui.Preview)
        assert preview.fetch and "aleksandra" in preview.fetch[0].plain
        await pilot.press("down")
        await pilot.pause()
        assert preview.slug == "light-two"
        shown = preview.render()
        # blank cells carry the glass background as half blocks
        assert "theme  light-two" in shown.plain.replace("▀", " "), "the theme line names the previewed theme"
        styles = [sp.style for sp in shown.spans if isinstance(sp.style, tui.Style)]
        colours = {str(st.color.triplet.hex) for st in styles if st.color and st.color.triplet}
        light = stub.LIGHT
        assert light["base08"] in colours, "the active theme's red is repainted as the previewed theme's red"
        assert light["base0B"] in colours, "ANSI green maps to the previewed base0B"
        assert stub.PAL["base08"] not in colours
        await pilot.press("enter")
        await settle(pilot)
        assert ["theme", "light-two"] in calls()


async def test_look_wallpaper_previews_before_applying(calls, tmp_path, monkeypatch):
    from PIL import Image

    wall = tmp_path / "wall.png"
    Image.new("RGB", (40, 20), (255, 255, 255)).save(wall)
    monkeypatch.setenv("STUB_WALL", str(wall))
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("4")
        await settle(pilot)
        preview = pilot.app.query_one(tui.Preview)
        assert preview.image is not None, "absent mode = on: the wallpaper shows"
        with_wall = preview.bg_grid(10, 5)
        await pilot.press("w")
        await settle(pilot)
        assert preview.image is None and preview.bg_grid(10, 5) != with_wall, "w turns the preview off"
        assert not [c for c in calls() if c[0] == "wallpaper"], "previewing applies nothing"
        await pilot.press("W")
        await settle(pilot)
        assert ["wallpaper", "off"] in calls(), "W applies what the preview shows"


async def test_look_glass_previews_before_applying(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("4", "g")
        await pilot.pause()
        preview = pilot.app.query_one(tui.Preview)
        glass = pilot.app.query_one("#glass-list", OptionList)
        levels = [o.id for o in glass.options]
        glass.highlighted = levels.index("solid")
        await pilot.pause()
        assert preview.glass == (1.0, "false") and preview.bg_grid(10, 5) is None, "solid: plain base00"
        glass.highlighted = levels.index("clear")
        await pilot.pause()
        assert preview.glass == (0.5, "macos-glass-clear")
        assert preview.bg_grid(10, 5)[0][0] != stub.PAL["base00"], "the desktop shows through"
        assert not [c for c in calls() if c[0] == "glass"], "previewing applies nothing"
        await pilot.press("enter")
        await settle(pilot)
        assert ["glass", "clear"] in calls()


async def test_look_glass_applies(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("4", "g")
        glass = pilot.app.query_one("#glass-list", OptionList)
        assert pilot.app.focused is glass
        assert [o.id for o in glass.options] == ["clear", "frosted", "solid", "default"]
        glass.highlighted = 1
        await pilot.press("enter")
        await settle(pilot)
        assert ["glass", "frosted"] in calls()


async def test_status_check_persists_across_launches(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("r")
        await settle(pilot)
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        assert calls().count(["doctor"]) == 1, "the second launch runs nothing"
        assert "health-fail" in attention(pilot) and "checked just now" in verdict(pilot)


async def test_tui_colours_follow_the_active_theme(calls, monkeypatch):
    monkeypatch.setenv("STUB_THEME", "light-two")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        theme = pilot.app.current_theme
        assert pilot.app.theme == "dotfiles"
        assert theme.background == "#f5f5f7"
        assert theme.dark is False


def proc_log(tmp_path, monkeypatch) -> Path:
    log = tmp_path / "procs.jsonl"
    monkeypatch.setenv("STUB_PROC", str(log))
    return log


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


async def test_children_get_no_terminal_and_no_git_prompts(calls, tmp_path, monkeypatch):
    log = proc_log(tmp_path, monkeypatch)
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
    procs = [json.loads(x) for x in log.read_text().splitlines()]
    assert procs, "the stub recorded no calls"
    assert all(p["leader"] for p in procs), "each child leads its own session (no controlling tty)"
    assert all(p["prompt"] == "0" for p in procs)


async def test_long_line_without_newline_does_not_crash(calls, monkeypatch):
    monkeypatch.setenv("STUB_BIG", "glass")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("4", "g")
        pilot.app.query_one("#glass-list", OptionList).highlighted = 0
        await pilot.press("enter")
        await settle(pilot)
        assert "done" in text(pilot.app.screen.query_one("#run-status", Label))
        assert "applied glass clear" in log_text(pilot.app.screen.query_one("#run-log", RichLog))


async def test_missing_cli_shows_errors_instead_of_crashing(calls, monkeypatch):
    monkeypatch.setenv("DOTFILES_CMD", "/nonexistent/dotfiles")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("r")
        await settle(pilot)
        assert attention(pilot)[0] == "health-fail"
        await pilot.press("enter")
        await pilot.pause()
        assert "cannot run the dotfiles CLI" in log_text(pilot.app.screen.query_one("#report", RichLog))
        await pilot.press("escape")
        await tools(pilot)
        assert "cannot run the dotfiles CLI" in text(pilot.app.query_one("#tool-empty"))


async def test_off_contract_tools_are_dropped_or_blanked(calls, monkeypatch):
    rows = [
        {"name": "ok", "group": None, "source": 3, "selected": True, "installed": True, "pinned": None, "actual": 1},
        "junk",
        {"group": "core"},
    ]
    monkeypatch.setenv("STUB_LIST", json.dumps(rows))
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        table = await tools(pilot)
        assert [str(k.value) for k in table.rows] == ["ok"]
        assert str(table.get_cell("ok", "version")) == ""
        assert "group" in text(pilot.app.query_one("#tool-detail"))


async def test_bad_palette_keeps_the_default_theme(calls, monkeypatch):
    monkeypatch.setenv("STUB_THEME", "bad-hex")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        assert pilot.app.theme != "dotfiles"


async def test_quit_while_running_needs_a_second_press_and_stops_the_command(calls, tmp_path, monkeypatch):
    log = proc_log(tmp_path, monkeypatch)
    monkeypatch.setenv("STUB_SLOW", "update")
    app = tui.DotfilesApp()
    async with app.run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("u")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(50):
            await pilot.pause(0.1)
            if any(json.loads(x)["argv"] == ["update"] for x in log.read_text().splitlines()):
                break
        pid = next(json.loads(x)["pid"] for x in log.read_text().splitlines() if json.loads(x)["argv"] == ["update"])
        await pilot.press("ctrl+q")
        await pilot.pause()
        assert app.is_running and isinstance(app.screen, tui.Run)
        assert alive(pid)
        await pilot.press("ctrl+q")
        await pilot.pause(0.5)
    for _ in range(50):
        if not alive(pid):
            break
        await asyncio.sleep(0.1)
    assert not alive(pid), "the running update was stopped on quit"


async def test_update_cancels_a_running_check_first(calls, tmp_path, monkeypatch):
    log = proc_log(tmp_path, monkeypatch)
    monkeypatch.setenv("STUB_SLOW", "update --check")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("r")
        for _ in range(50):
            await pilot.pause(0.1)
            if "--check" in log.read_text():
                break
        check = next(json.loads(x)["pid"] for x in log.read_text().splitlines() if "--check" in x)
        await pilot.press("u")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(50):
            await pilot.pause(0.1)
            if ["update"] in calls() and not alive(check):
                break
        assert ["update"] in calls()
        assert not alive(check), "the slow check was stopped before update ran"


READS = {
    ("list", "--json"),
    ("look", "--json"),
    ("files", "--json"),
    ("machine", "--json"),
    ("look", "--fetch"),
    ("look", "--fetch", "--no-logo"),
}


async def test_opening_tabs_runs_nothing(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("2", "3", "4", "5", "1", "3")
        await pilot.pause(0.3)
        await settle(pilot)
        ran = {tuple(c) for c in calls()}
        assert ran - READS <= {("files", "diff", ".config/ghostty/config")}, f"only reads: {ran - READS}"


async def test_escape_leaves_the_filter_so_tab_keys_work(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await tools(pilot)
        await pilot.press("slash", *"zzz")
        await pilot.pause()
        assert "No tools match" in text(pilot.app.query_one("#tool-empty"))
        await pilot.press("escape", "3")
        await pilot.pause()
        assert pilot.app.query_one("#tool-filter", Input).value == ""
        assert pilot.app.query_one(tui.TabbedContent).active == "files"


async def test_narrow_terminal_hides_the_about_panel(calls):
    async with tui.DotfilesApp().run_test(size=(80, 24)) as pilot:
        await tools(pilot)
        assert not pilot.app.query_one("#tool-detail-box").display


async def test_tab_bar_arrows_keep_focus_on_the_tab_bar(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        pilot.app.query_one(tui.Tabs).focus()
        await pilot.press("right", "right")
        await settle(pilot)
        assert pilot.app.query_one(tui.TabbedContent).active == "files"
        assert isinstance(pilot.app.focused, tui.Tabs), "focus stays on the tab bar"
        await pilot.press("down")
        await pilot.pause()
        assert pilot.app.focused is pilot.app.query_one("#file-list", OptionList)
        await pilot.press("5")
        await pilot.pause()
        assert pilot.app.focused is pilot.app.query_one("#m-git_name", Input), "number keys go into the tab"


async def test_f2_cycles_the_look_and_remembers_it(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        assert pilot.app.screen.has_class("style-boxes")
        await pilot.press("f2")
        await pilot.pause()
        assert pilot.app.screen.has_class("style-minimal") and not pilot.app.screen.has_class("style-boxes")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        assert pilot.app.screen.has_class("style-minimal"), "the choice survives a restart"


def main() -> int:
    paths = [str(REPO / "scripts" / "tui"), str(HERE)]
    for cmd in (["ruff", "check", *paths], ["ruff", "format", "--check", *paths]):
        if subprocess.call([sys.executable, "-m", *cmd], cwd=REPO):
            return 1
    os.chdir(REPO)
    # a hung pilot test must fail the run, not stall CI
    faulthandler.dump_traceback_later(300, exit=True)
    return pytest.main(["-q", "-p", "no:cacheprovider", "-o", "asyncio_mode=auto", __file__])


if __name__ == "__main__":
    sys.exit(main())
