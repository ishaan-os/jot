<p align="center"><img src="assets/icon-1024.png" width="128" alt="Jot icon"></p>
<h1 align="center">Jot</h1>
<p align="center"><b>Collect thoughts & questions while you review AI output — then drop them all back in one keystroke.</b></p>

<p align="center"><img src="assets/demo.gif" alt="Jot demo: capture a selection with ⇧⇧, annotate it, jot a thought with ⌘⌘, paste everything with ⌃⌃"></p>

Reviewing a long AI answer, a diff, or a plan, you keep having reactions that aren't ready to send yet.
Jot is a tiny floating scratchpad for exactly that: grab the sentence that bugged you, add a note,
keep reading. When you're ready, paste the whole batch — quoted and annotated — into whatever chat
or editor your cursor is in.

- **Works everywhere.** Global gestures, any app: browsers, terminals, editors, chat apps.
- **Never steals your place.** The widget floats without activating; paste lands at *your* cursor.
- **Tiny.** One Swift file, no dependencies, no account, no network. Notes live in a local JSON file.

## Gestures

| | | |
|---|---|---|
| **⇧⇧** | tap Shift twice | Capture the selected text, then type an optional note (**↩** saves and returns you to your app, **esc** skips the note) |
| **⌘⌘** | tap Command twice | Jot a thought in the widget; **↩** saves and keeps the cursor for the next one. Again to go back |
| **⌃⌃** | tap Control twice | Paste checked items (or all) at your cursor, then clear them |

In the widget: **⌘↩** paste · **⌘⇧C** copy · **⌘⇧⌫** clear (with undo) · **⌘⇧A** select all/none.
Click an item to edit its note; click its circle to check it. The close button tucks Jot into the
menu bar (left-click the icon to bring it back, right-click for the menu).

Pasted output is plain markdown:

```
> It runs in a single transaction so the table is never half-migrated.
single txn on a big table — safe under load?

ask for a test on the 5th-retry path
```

<p align="center"><img src="assets/hero.png" width="800" alt="Jot widget next to an AI chat window"></p>

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone <this repo> && cd jot
./build.sh                  # builds and installs ~/Applications/Jot.app
open ~/Applications/Jot.app
```

Then allow Jot in **System Settings → Privacy & Security → Accessibility** (the widget shows a
banner until you do). Jot needs it to read your selection and to type the paste for you.

> Builds are ad-hoc signed, so macOS forgets the Accessibility grant after every rebuild —
> remove Jot from the list and add it again.

Right-click the menu-bar icon → **Launch at Login** to keep it around.

## How it works

- Double taps are detected from global `flagsChanged` events: a lone modifier pressed and released
  twice within ~0.4s with nothing else in between, so Shift-typing and Shift-clicking don't trigger it.
- Capture reads the selection via the Accessibility API; apps that don't expose it (many terminals,
  Electron) fall back to a synthetic ⌘C with your clipboard restored right after.
- The widget is a non-activating `NSPanel`, which is why paste can send ⌘V to the app you were in.
- Items: `~/Library/Application Support/Jot/items.json` · debug log: `~/Library/Logs/Jot.log`.

## Media

Everything under `assets/` is rendered from a scripted SwiftUI mock (`promo/Promo.swift`) — no screen
recording. `promo/render.sh` regenerates `hero.png`, `widget.png`, `demo.gif` and `demo.mp4`.
The icon is `promo/icon.svg`.

## Credits

Gesture design inspired by [Copper](https://shadcn.com/copper) by shadcn — if you want a polished,
supported app, go buy it. Jot is a small open-source take on the same idea.

## License

MIT
