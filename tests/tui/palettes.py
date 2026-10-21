"""Real palettes from the repo (catppuccin-mocha, iglass-light) for the TUI tests."""

PAL = dict(
    zip(
        [f"base0{c}" for c in "0123456789ABCDEF"],
        [
            "#1e1e2e",
            "#181825",
            "#313244",
            "#45475a",
            "#585b70",
            "#cdd6f4",
            "#f5e0dc",
            "#b4befe",
            "#f38ba8",
            "#fab387",
            "#f9e2af",
            "#a6e3a1",
            "#94e2d5",
            "#89b4fa",
            "#cba6f7",
            "#f2cdcd",
        ],
        strict=True,
    )
)
LIGHT = dict(
    zip(
        PAL,
        [
            "#f5f5f7",
            "#e5e5ea",
            "#bad7f9",
            "#605f64",
            "#3a3a3c",
            "#1d1d1f",
            "#1d1d1f",
            "#000000",
            "#92000b",
            "#c30006",
            "#763200",
            "#00521b",
            "#004a6e",
            "#0035bb",
            "#6a238a",
            "#902fbd",
        ],
        strict=True,
    )
)
