# NotchTerm

**A terminal that lives in your notch.** Hover your mouse over the MacBook notch and a terminal drops down. Move away and it hides. Your shell keeps running the whole time.

No Dock icon, no keyboard shortcut to remember, no window management — just a flick of the wrist.

- **Website & docs:** https://ysftrn.github.io/NotchTerm/
- **Download:** [Releases](https://github.com/ysftrn/NotchTerm/releases)

## Features

- **Hover to show, hover-off to hide** — the shell session persists across show/hide
- **Tabs** — Cmd+T for a new tab, tab strip appears only when you have 2+ (position configurable: top or bottom)
- **25 built-in themes** with full ANSI palettes — Catppuccin, Dracula, Gruvbox, Nord, Rose Pine, Solarized, Tokyo Night, and more
- **Works on every screen** — real notch on MacBooks, a "phantom notch" (top-center hover zone) on external monitors and non-notch Macs
- **Plain-text config** with live reload — edit, save, applied instantly
- **TUI-friendly** — vim, htop, less all work; Escape reaches the terminal
- **Any shell** — zsh, bash, fish, whatever `$SHELL` says (or override in config)
- **Bundled Nerd Font** (MesloLGS) — prompt glyphs work out of the box

## Install

### Download (recommended)

1. Grab `NotchTerm.zip` from the [latest release](https://github.com/ysftrn/NotchTerm/releases/latest) and unzip it.
2. Move `NotchTerm.app` to `/Applications`.
3. NotchTerm is not notarized yet (indie app, no Apple Developer subscription — it's on the roadmap). macOS will block the first launch, so clear the quarantine flag:

```sh
xattr -d com.apple.quarantine /Applications/NotchTerm.app
```

   Or: try to open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

4. On first launch, grant **Accessibility** access when prompted. NotchTerm needs it to see mouse movement over the notch while other apps are focused. It does **not** log keystrokes, read screen content, or send anything anywhere — the code is right here to check.

### Build from source

```sh
git clone https://github.com/ysftrn/NotchTerm.git
cd NotchTerm
xcodebuild -project NotchTerm.xcodeproj -scheme NotchTerm -configuration Release build
```

Requires Xcode 15+ and macOS 13+.

## Usage

Hover the notch (or the top-center of any screen's menu bar). That's it.

| Shortcut | Action |
|---|---|
| `Cmd+T` | New tab |
| `Cmd+W` | Close tab (hides panel on the last tab) |
| `Cmd+1`–`9` | Jump to tab |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous tab |
| `Cmd+K` | Clear terminal |
| `Cmd+C` / `Cmd+V` | Copy / paste |
| `Cmd+,` | Open config file |
| `Cmd+R` | Reload config (edits auto-apply on save anyway) |
| `Cmd+Q` | Quit |

Typing `exit` (or Ctrl+D) closes the current tab; the last tab restarts its shell instead. Drag any edge of the panel to resize — it stays centered under the notch.

## Configuration

Everything lives in `~/.config/notchterm/notchterm.conf` — open it with `Cmd+,`. Changes apply the moment you save.

```conf
font-family = MesloLGSNerdFont-Regular
font-size = 13              # points, 8–36

theme = Default             # see the theme list below
opacity = 1.0               # 0.1 – 1.0
cursor-style = block        # block | underline | bar
cursor-blink = false        # true | false

shell = /bin/zsh            # full path to the shell executable
scrollback = 10000          # lines kept in history (min 100)

width = 1000                # points (min 300)
height = 400                # points; 0 = 40% of screen height
terminal-padding = 0        # inner inset, 0–40
notch-gap = 0               # gap below the notch, 0–50
tab-position = bottom       # tab bar edge: top | bottom
```

### Themes

Default, Ayu, Ayu Mirage, Catppuccin Frappe, Catppuccin Latte, Catppuccin Macchiato, Catppuccin Mocha, Dracula, Everforest Dark, GitHub Dark, GitHub Light, Gruvbox Dark, Gruvbox Light, Monokai, Nord, One Dark, One Light, Rose Pine, Rose Pine Dawn, Rose Pine Moon, Snazzy, Solarized Dark, Solarized Light, Tokyo Night, Tokyo Night Storm

All themes include complete 16-color ANSI palettes plus matching cursor and selection colors.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel
- A notch is *not* required — non-notch screens get a phantom hover zone at the top-center

## Privacy

NotchTerm runs entirely on your machine and **does not log, record, or transmit any user information — ever**. No keystroke logging, no screen recording, no analytics, no telemetry, no crash reporting, no network calls, no account. The Accessibility permission is used solely to observe the mouse position for the hover trigger, and everything the app does is auditable in this repository.

## Credits

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza — the terminal engine (MIT)
- Theme palettes collected from [iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)
- [MesloLGS Nerd Font](https://github.com/ryanoasis/nerd-fonts) (Apache 2.0 / OFL)
- Theme designs by their respective authors: Catppuccin, Dracula, Gruvbox, Nord, Rose Pine, Solarized, Tokyo Night, and others — thank you

## License

[MIT](LICENSE) © Yusuf Torun
