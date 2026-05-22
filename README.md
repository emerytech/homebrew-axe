# Axe

A macOS menu bar app for quickly killing running applications. Press **⌥⌘K** anywhere to pop a Spotlight-style overlay, type to filter, then click (or press Return) to quit an app — ⌘-click or ⌘Return to force-kill it instantly.

## Install

```sh
brew install emerytech/axe/axe
```

Then open `Axe.app` from the path brew prints in its caveats.

## Usage

| Action | Effect |
|--------|--------|
| **⌥⌘K** | Toggle the overlay (global hotkey, no Accessibility permission needed) |
| Left-click menu bar icon | Toggle the overlay |
| Right-click menu bar icon | Show menu (toggle / quit Axe) |
| Type | Filter running apps by name |
| ↑ / ↓ | Navigate the list |
| Click a row | Graceful quit (SIGTERM → SIGKILL after 2 s) |
| ⌘-click a row | Force kill immediately (SIGKILL) |
| Return | Graceful kill selected app |
| ⌘Return | Force kill selected app |
| Escape | Dismiss overlay |

Only regular GUI apps appear in the list — background agents, helpers, and Axe itself are excluded.

## Build from source

```sh
git clone https://github.com/emerytech/homebrew-axe.git
cd homebrew-axe
./menubar/build.sh    # produces menubar/Axe.app
open menubar/Axe.app
```

## License

[MIT](LICENSE)
