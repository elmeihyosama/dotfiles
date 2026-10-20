# /// script
# requires-python = ">=3.13"
# dependencies = [
#   "textual==8.2.8",
#   "pytest==9.1.1",
#   "pytest-asyncio==1.4.0",
#   "ruff==0.16.10",
# ]
# ///
"""TUI tests (Textual's headless pilot against a stub CLI), plus ruff.

Run: uv run --locked --script tests/tui/test_tui.py (tests/tui.test.sh does).
"""

from __future__ import annotations

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
from textual.widgets import DataTable, Input, Label, OptionList, RichLog  # noqa: E402

SIZE = (120, 40)


@pytest.fixture
def calls(tmp_path, monkeypatch):
    """Point the TUI at the stub; return a reader for the recorded argvs."""
    log = tmp_path / "calls.jsonl"
    log.touch()
    monkeypatch.setenv("STUB_LOG", str(log))
    monkeypatch.setenv("DOTFILES_CMD", f"{sys.executable} {HERE / 'stub_dotfiles.py'}")
    for var in ("STUB_FAIL", "STUB_LIST", "STUB_THEME"):
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


async def test_tools_table_shows_catalog_and_drift(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        table = pilot.app.query_one("#tool-table", DataTable)
        assert table.row_count == 4
        assert [str(k.value) for k in table.rows] == ["fzf", "ripgrep", "lazygit", "zellij"]
        assert str(table.get_cell("ripgrep", "actual")) == "14.0.0"
        summary = text(pilot.app.query_one("#tool-summary", Label))
        assert "4/4 tools" in summary
        assert "1 not at their pin" in summary
        assert "1 selected but missing" in summary
        assert ["list", "--json"] in calls()


async def test_filter_narrows_rows(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("slash", *"git")
        await pilot.pause()
        table = pilot.app.query_one("#tool-table", DataTable)
        assert [str(k.value) for k in table.rows] == ["lazygit"]
        assert pilot.app.focused is pilot.app.query_one("#tool-filter", Input)


async def test_marks_apply_add_and_remove_after_confirm(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        pilot.app.query_one("#tool-table", DataTable).focus()
        # fzf (selected) -> remove; skip ripgrep; lazygit (unselected) -> add
        await pilot.press("space", "down", "space")
        await pilot.pause()
        table = pilot.app.query_one("#tool-table", DataTable)
        assert str(table.get_cell("fzf", "mark")) == "−"
        assert str(table.get_cell("lazygit", "mark")) == "+"
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
        await settle(pilot)
        pilot.app.query_one("#tool-table", DataTable).focus()
        await pilot.press("space", "a")
        await pilot.pause()
        await pilot.press("n")
        await settle(pilot)
        assert not [c for c in calls() if c[0] in ("add", "remove")]


async def test_failed_apply_keeps_marks(calls, monkeypatch):
    monkeypatch.setenv("STUB_FAIL", "remove")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        pilot.app.query_one("#tool-table", DataTable).focus()
        await pilot.press("space", "a")
        await pilot.pause()
        await pilot.press("y")
        await settle(pilot)
        status = text(pilot.app.screen.query_one("#run-status", Label))
        assert "failed (exit 1)" in status
        await pilot.press("escape")
        await settle(pilot)
        assert "1 marked" in text(pilot.app.query_one("#tool-summary", Label))


async def test_bad_list_output_shows_error(calls, monkeypatch):
    monkeypatch.setenv("STUB_LIST", "not json")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        assert pilot.app.query_one("#tool-table", DataTable).row_count == 0
        assert "dotfiles list failed" in text(pilot.app.query_one("#tool-summary", Label))


async def test_health_runs_doctor_once_and_counts(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("2")
        await settle(pilot)
        summary = text(pilot.app.query_one("#health-summary", Label))
        assert "2 ok" in summary and "1 warn" in summary and "1 fail" in summary
        assert "zellij missing" in log_text(pilot.app.query_one("#health-log", RichLog))
        await pilot.press("1", "2")
        await settle(pilot)
        assert calls().count(["doctor"]) == 1
        await pilot.press("r")
        await settle(pilot)
        assert calls().count(["doctor"]) == 2


async def test_update_checks_on_open_and_updates_after_confirm(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("3")
        await settle(pilot)
        assert ["update", "--check"] in calls()
        assert "abc1234" in log_text(pilot.app.query_one("#update-log", RichLog))
        await pilot.press("u")
        await pilot.pause()
        await pilot.press("y")
        await settle(pilot)
        assert ["update"] in calls()
        await pilot.press("escape")
        await settle(pilot)
        assert calls().count(["update", "--check"]) == 2


async def test_look_previews_and_applies_theme_and_glass(calls):
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        await pilot.press("4")
        await settle(pilot)
        themes = pilot.app.query_one("#theme-list", OptionList)
        assert [o.id for o in themes.options] == ["dark-one", "light-two"]
        assert themes.highlighted == 0
        themes.focus()
        await pilot.press("down")
        await pilot.pause()
        assert "light-two" in text(pilot.app.query_one("#swatch"))
        await pilot.press("enter")
        await settle(pilot)
        assert ["theme", "light-two"] in calls()
        await pilot.press("escape")
        await settle(pilot)
        glass = pilot.app.query_one("#glass-list", OptionList)
        assert [o.id for o in glass.options] == ["clear", "frosted", "solid", "default"]
        glass.focus()
        glass.highlighted = 1
        await pilot.press("enter")
        await settle(pilot)
        assert ["glass", "frosted"] in calls()


async def test_tui_colours_follow_the_active_theme(calls, monkeypatch):
    monkeypatch.setenv("STUB_THEME", "light-two")
    async with tui.DotfilesApp().run_test(size=SIZE) as pilot:
        await settle(pilot)
        theme = pilot.app.current_theme
        assert pilot.app.theme == "dotfiles"
        assert theme.background == "#f5f5f7"
        assert theme.dark is False


def main() -> int:
    paths = [str(REPO / "scripts" / "tui"), str(HERE)]
    for cmd in (["ruff", "check", *paths], ["ruff", "format", "--check", *paths]):
        if subprocess.call([sys.executable, "-m", *cmd], cwd=REPO):
            return 1
    os.chdir(REPO)
    return pytest.main(["-q", "-p", "no:cacheprovider", "-o", "asyncio_mode=auto", __file__])


if __name__ == "__main__":
    sys.exit(main())
