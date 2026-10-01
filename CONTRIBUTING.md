# Contributing

Jot is intentionally small: one Swift file (`main.swift`), no dependencies, no project file.

- **Build & run:** `./build.sh && open ~/Applications/Jot.app` (needs the Xcode Command Line Tools).
- **Keep it simple.** Jot's whole pitch is three gestures and nothing to configure — new features
  should fit into the existing note field, `/commands`, or the menu-bar menu rather than add UI.
- **Watch for shortcut clashes.** Global gestures collide easily with other apps (Wispr Flow,
  window managers, the Claude desktop app); explain the trade-off in your PR.
- **Demo media** is generated, not recorded: `promo/render.sh` (see `promo/Promo.swift`).
- Add a line to `CHANGELOG.md` under *Unreleased*.

## Releasing

1. Bump `VERSION`, move *Unreleased* notes in `CHANGELOG.md` under the new version, commit.
2. `git tag vX.Y.Z && git push origin vX.Y.Z` — the release workflow builds a universal app, signs it
   with the Developer ID, notarizes it, and publishes `Jot-X.Y.Z.dmg` with the changelog notes.
3. Update `version` and `sha256` (`shasum -a 256 Jot-X.Y.Z.dmg`) in
   [ishaan-os/homebrew-tap](https://github.com/ishaan-os/homebrew-tap) `Casks/jot.rb`.
