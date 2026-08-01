import AppKit

// MARK: - Color scheme presets

enum ColorSchemePreset: String, CaseIterable {
    case `default`     = "Default"
    case dracula       = "Dracula"
    case catppuccin    = "Catppuccin"
    case solarizedDark = "Solarized Dark"
    case oneDark       = "One Dark"

    var background: NSColor {
        switch self {
        case .default:       return NSColor(white: 0.12, alpha: 1)
        case .dracula:       return NSColor(srgbRed: 0x28/255, green: 0x2A/255, blue: 0x36/255, alpha: 1)
        case .catppuccin:    return NSColor(srgbRed: 0x1E/255, green: 0x1E/255, blue: 0x2E/255, alpha: 1)
        case .solarizedDark: return NSColor(srgbRed: 0x00/255, green: 0x2B/255, blue: 0x36/255, alpha: 1)
        case .oneDark:       return NSColor(srgbRed: 0x28/255, green: 0x2C/255, blue: 0x34/255, alpha: 1)
        }
    }

    var foreground: NSColor {
        switch self {
        case .default:       return NSColor(white: 0.9, alpha: 1)
        case .dracula:       return NSColor(srgbRed: 0xF8/255, green: 0xF8/255, blue: 0xF2/255, alpha: 1)
        case .catppuccin:    return NSColor(srgbRed: 0xCD/255, green: 0xD6/255, blue: 0xF4/255, alpha: 1)
        case .solarizedDark: return NSColor(srgbRed: 0x83/255, green: 0x94/255, blue: 0x96/255, alpha: 1)
        case .oneDark:       return NSColor(srgbRed: 0xAB/255, green: 0xB2/255, blue: 0xBF/255, alpha: 1)
        }
    }

    /// Case-insensitive lookup for config file values (e.g. "dracula", "Solarized Dark").
    static func from(_ string: String) -> ColorSchemePreset? {
        allCases.first { $0.rawValue.lowercased() == string.lowercased() }
    }
}

// MARK: - Settings

/// Reads configuration from `~/.config/notchterm/notchterm.conf`.
/// A default file is written on first launch. Use Reload Config from the
/// menu bar to pick up changes.
final class Settings {
    static let shared = Settings()
    static let didChangeNotification = Notification.Name("NotchTermSettingsDidChange")

    static let configDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/notchterm", isDirectory: true)
    }()
    static let configFile: URL = configDir.appendingPathComponent("notchterm.conf")

    private var parsed: [String: String] = [:]

    private init() {
        ensureConfigExists()
        loadParsed()       // silent load — no notification on init
        migrateMissingKeys()
    }

    // MARK: - Typed accessors (all read from `parsed`)

    var fontFamily: String { parsed["font-family"] ?? "MesloLGSNerdFont-Regular" }

    var fontSize: CGFloat {
        guard let s = parsed["font-size"], let v = Double(s) else { return 13 }
        return CGFloat(max(8, min(36, v)))
    }

    var colorScheme: ColorSchemePreset {
        guard let s = parsed["theme"] else { return .default }
        return ColorSchemePreset.from(s) ?? .default
    }

    var opacity: Double {
        guard let s = parsed["opacity"], let v = Double(s) else { return 1.0 }
        return max(0.1, min(1.0, v))
    }

    /// Cursor shape: "block", "underline", or "bar". Default: "block".
    var cursorShape: String {
        let s = (parsed["cursor-style"] ?? "block").lowercased()
        return ["block", "underline", "bar"].contains(s) ? s : "block"
    }

    /// Whether the cursor blinks. Default: false.
    var cursorBlink: Bool {
        guard let s = parsed["cursor-blink"] else { return false }
        return s.lowercased() == "true"
    }

    var shell: String {
        parsed["shell"]
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
    }

    /// Scrollback line count. Applied via `Terminal.changeScrollback()` whenever
    /// settings reload — takes effect immediately without a shell respawn.
    var scrollback: Int {
        guard let s = parsed["scrollback"], let v = Int(s) else { return 10000 }
        return max(100, v)
    }

    /// Panel width in points, read from config.
    var panelWidth: CGFloat {
        guard let s = parsed["width"], let v = Double(s) else { return 600 }
        return CGFloat(max(300, v))
    }

    /// Panel height in points, read from config.
    /// 0 means "use the 40 % of screen-height default".
    var panelHeight: CGFloat {
        guard let s = parsed["height"], let v = Double(s) else { return 0 }
        return CGFloat(max(150, v))
    }

    /// Inner padding in points applied between the panel edges and the
    /// terminal view. Range: 0–40.
    var terminalPadding: CGFloat {
        guard let s = parsed["terminal-padding"], let v = Double(s) else { return 6 }
        return CGFloat(max(0, min(40, v)))
    }

    /// Vertical gap in points between the bottom of the notch and the top of
    /// the panel. A small value (e.g. 4–8) creates a perceptible separation
    /// from the notch and a buffer zone that reduces accidental dismissals.
    /// Range: 0–50.
    var notchGap: CGFloat {
        guard let s = parsed["notch-gap"], let v = Double(s) else { return 0 }
        return CGFloat(max(0, min(50, v)))
    }

    // MARK: - Font resolution

    /// Returns the configured font, falling back through common Nerd Font
    /// names to the system monospace font.
    func resolvedFont() -> NSFont {
        let size = fontSize
        if !fontFamily.isEmpty, let font = NSFont(name: fontFamily, size: size) {
            return font
        }
        let fallbacks = [
            "MesloLGS Nerd Font", "MesloLGSNerdFont-Regular",
            "HackNerdFont-Regular", "Hack Nerd Font",
            "FiraCodeNerdFont-Regular", "FiraCode Nerd Font",
            "JetBrainsMonoNerdFont-Regular", "JetBrainsMono Nerd Font",
            "SF Mono", "SFMono-Regular", "Menlo",
        ]
        return fallbacks.lazy.compactMap { NSFont(name: $0, size: size) }.first
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Config file actions

    /// Opens the config file in the user's default text editor.
    func openConfigFile() {
        NSWorkspace.shared.open(Self.configFile)
    }

    /// Re-reads the config file and posts `didChangeNotification`.
    func reload() {
        loadParsed()
        notifyChanged()
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Private

    private func loadParsed() {
        parsed = Self.parse(file: Self.configFile)
    }

    private static func parse(file: URL) -> [String: String] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            // Strip inline comment, then trim whitespace.
            let line = (rawLine.components(separatedBy: "#").first ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Split on the FIRST '=' only (values can contain '=').
            guard let eqRange = line.range(of: "=") else { continue }
            let key   = line[line.startIndex..<eqRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let value = line[eqRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// Append documentation + default values for keys that didn't exist in
    /// older versions of the config file. Runs once at launch so users who
    /// already have a `notchterm.conf` from a previous version still see
    /// (and can edit) the new keys without losing their existing edits.
    /// If the user has commented a key out, it counts as "missing" and gets
    /// appended again — that's a deliberate fallback to the documented
    /// defaults. The new section lands at the bottom with section headers.
    private func migrateMissingKeys() {
        let url = Self.configFile
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return }

        var additions: [String] = []
        if parsed["terminal-padding"] == nil {
            additions.append("""
            # terminal-padding: inner padding in points between the panel
            # edges and the terminal view. Affects all four sides.
            #   Range: 0 – 40

            terminal-padding = 6
            """)
        }
        if parsed["notch-gap"] == nil {
            additions.append("""
            # notch-gap: vertical distance in points between the bottom of
            # the notch and the top of the panel. A small gap visually
            # separates the window from the notch and creates a mouse buffer
            # zone that reduces accidental dismissals.
            #   Range: 0 – 50

            notch-gap = 0
            """)
        }

        guard !additions.isEmpty else { return }

        let header = "\n\n# ── Added in 0.1.6 ────────────────────────────────────────────────────────\n\n"
        let appended = original + header + additions.joined(separator: "\n\n") + "\n"
        do {
            try appended.write(to: url, atomically: true, encoding: .utf8)
            parsed = Self.parse(file: url)
        } catch {
            print("[NotchTerm] Failed to migrate config file: \(error.localizedDescription)")
        }
    }

    private func ensureConfigExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.configDir.path) {
            do {
                try fm.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
            } catch {
                print("[NotchTerm] Failed to create config directory: \(error.localizedDescription)")
                return
            }
        }
        guard !fm.fileExists(atPath: Self.configFile.path) else { return }

        let defaultShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let content = """
        # NotchTerm configuration
        # Location: ~/.config/notchterm/notchterm.conf
        #
        # Edit and save, then click Reload Config in the menu bar to apply changes.
        # Both "key = value" and "key=value" are accepted. Lines starting with
        # '#' and inline comments after '#' are ignored.


        # ── Font ──────────────────────────────────────────────────────────────────
        #
        # font-family: PostScript name or family name of a monospace font.
        #
        #   Bundled (works out of the box, includes Nerd Font glyphs):
        #     font-family = MesloLGSNerdFont-Regular
        #
        #   Other Nerd Fonts (install from https://www.nerdfonts.com):
        #     font-family = JetBrainsMonoNerdFont-Regular
        #     font-family = HackNerdFont-Regular
        #     font-family = FiraCodeNerdFont-Regular
        #
        #   System fonts (always available, no Nerd Font glyphs):
        #     font-family = Menlo
        #     font-family = SF Mono
        #
        # Leave blank to use the built-in MesloLGS Nerd Font default.

        font-family = MesloLGSNerdFont-Regular
        font-size = 13          # points; valid range 8–36


        # ── Appearance ────────────────────────────────────────────────────────────
        #
        # theme: built-in color scheme preset.
        #   Options: Default, Dracula, Catppuccin, Solarized Dark, One Dark

        theme = Default

        # opacity: overall panel transparency.
        #   Range: 0.1 (nearly transparent) – 1.0 (fully opaque)

        opacity = 1.0

        # cursor-style: shape of the terminal cursor.
        #   Options: block, underline, bar

        cursor-style = block

        # cursor-blink: whether the cursor blinks.
        #   Options: true, false

        cursor-blink = false

        # ── Terminal ──────────────────────────────────────────────────────────────
        #
        # shell: full path to the shell executable.
        #   Examples: /bin/zsh   /bin/bash   /opt/homebrew/bin/fish

        shell = \(defaultShell)

        # scrollback: number of lines kept in the scroll buffer.
        #   Range: 100 – unlimited (large values use more memory)

        scrollback = 10000


        # ── Window ────────────────────────────────────────────────────────────────
        #
        # width: panel width in points.
        #   Range: 300 – screen width

        width = 600

        # height: panel height in points.
        #   Range: 150 – screen height

        height = 400

        # terminal-padding: inner padding in points between the panel edges
        # and the terminal view. Affects all four sides.
        #   Range: 0 – 40

        terminal-padding = 6

        # notch-gap: vertical distance in points between the bottom of the
        # notch and the top of the panel. A small gap visually separates the
        # window from the notch and creates a mouse buffer zone that reduces
        # accidental dismissals.
        #   Range: 0 – 50

        notch-gap = 0
        """
        do {
            try content.write(to: Self.configFile, atomically: true, encoding: .utf8)
        } catch {
            print("[NotchTerm] Failed to write default config: \(error.localizedDescription)")
        }
    }

}
