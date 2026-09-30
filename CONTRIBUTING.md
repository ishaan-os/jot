# Contributing

Jot is intentionally small: one Swift file (`main.swift`), no dependencies, no project file.

- **Build & run:** `./build.sh && open ~/Applications/Jot.app` (needs the Xcode Command Line Tools).
- **Keep it simple.** Jot's whole pitch is three gestures and nothing to configure — new features
  should fit into the existing note field, `/commands`, or the menu-bar menu rather than add UI.
- **Watch for shortcut clashes.** Global gestures collide easily with other apps (Wispr Flow,
  window managers, the Claude desktop app); explain the trade-off in your PR.
- **Demo media** is generated, not recorded: `promo/render.sh` (see `promo/Promo.swift`).
- Add a line to `CHANGELOG.md` under *Unreleased*.
