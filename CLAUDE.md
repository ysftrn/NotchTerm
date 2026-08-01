# CLAUDE.md — NotchTerm

## What This App Does
A macOS menu bar utility: hover the mouse over the MacBook notch (or a
"phantom notch" zone at the top-center of any non-notch screen) and a
terminal panel drops down. Move away and it hides. Shell sessions persist
across show/hide. Free, open source (MIT), distributed as an unsigned
zip via GitHub Releases (no Apple Developer account yet).

- Repo: https://github.com/ysftrn/NotchTerm
- Site: https://ysftrn.github.io/NotchTerm/ (served from `/docs` on main)

## Tech Stack & Hard Rules
- macOS 13.0+, Swift, **AppKit only — no SwiftUI under any circumstances**
- Terminal engine: SwiftTerm (LocalProcess) — **the only third-party dependency**
- No sandbox (required for shell spawning); LSUIElement = true (menu bar only)
- **No force unwraps** — handle all errors explicitly
- Hide must use `orderOut` — never move the window off screen, never
  `NSApp.hide()` (it broke re-show in past prototypes)
- Shell processes must survive hide/show cycles
- Must work with zsh, bash, and fish

## Build & Run
Command-line tools alone can't build this; point at Xcode.app:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project NotchTerm.xcodeproj -scheme NotchTerm \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -quiet
```

Debug binary lands in `~/Library/Developer/Xcode/DerivedData/NotchTerm-*/Build/Products/Debug/`.
New source files must be registered manually in `project.pbxproj`
(objectVersion 56 — no filesystem-synchronized groups).

## Architecture (one file each, flat under /NotchTerm/)
- `AppDelegate` — status item, per-screen trigger monitors, panel
  show/hide orchestration, dismiss monitor, Cmd-shortcut local monitor
  (tabs, copy/paste, menu key equivalents), Accessibility prompt/polling
- `NotchDetector` — `detectAll()` returns a `NotchInfo` per screen: real
  notch rect where present, else a 180pt phantom strip at top-center
- `MouseMonitor` — global+local mouse-moved watcher for a rect
  (+ additional rects); onEnter/onExit
- `TerminalPanel` — borderless nonactivating NSPanel; horizontal
  symmetry enforced (always centered under the active screen's notch)
  via `constrained()` in setFrame overrides; fade show/hide
- `TabContainerView` — owns the tabs (each a `TerminalContentView` with
  its own shell), the rounded-corner mask, and `TabBarView` (flat,
  theme-colored strip, visible only with 2+ tabs; position from config)
- `TerminalContentView` — wraps SwiftTerm's `LocalProcessTerminalView`:
  shell lifecycle, sleep/wake recovery, respawn-on-exit (or
  `onProcessExit` callback in tab mode), scroller auto-hide (KVO),
  tab title tracking
- `ResizeBorderView` — transparent overlay widening the resize hit
  zone; custom drag loop; slim edges while the tab bar is visible
- `Settings` — config parsing + typed accessors + file watcher
- `Theme` — 25 full-ANSI-palette schemes + name lookup with aliases
- `WelcomeWindowController` — first-launch onboarding

## Config System (important invariants)
- File: `~/.config/notchterm/notchterm.conf`, plain `key = value`, `#` comments
- Auto-reloads on save (DispatchSource watcher in Settings; debounced;
  silent when values unchanged)
- The file is **rewritten from a canonical template** on format bumps:
  `Settings.configFormat` + the `# config-format: N` marker line. When
  adding a config key: add the typed accessor, add to `knownKeys`, add a
  `line(...)` to `canonicalContent`, and **bump `configFormat`** — users'
  values are preserved, their comments are not (documented in the header)
- Theme list in the template is generated from `Theme.all` — never
  hardcode theme names in docs strings

## Behavioral decisions (deliberate, don't "fix")
- No Esc-to-hide — Escape always reaches the terminal (vim needs it);
  hover-off is the only dismissal
- `exit`/Ctrl+D closes the tab; the last tab respawns instead
- Splits were rejected in favor of tabs (panel too small)
- Phantom notch instead of user-drawn trigger zones (product identity)
- Selection colors applied at 40% alpha (palettes ship them opaque)

## Release Process
1. Bump `MARKETING_VERSION` in project.pbxproj
2. Release build (same xcodebuild line, `-configuration Release`)
3. `ditto -c -k --keepParent NotchTerm.app NotchTerm.zip`
4. `gh release create vX.Y.Z NotchTerm.zip`
5. Users clear quarantine themselves (`xattr -d com.apple.quarantine`) —
   documented in README and the site
