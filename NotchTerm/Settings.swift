import AppKit
import UniformTypeIdentifiers

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
    private var configWatcher: DispatchSourceFileSystemObject?
    private var pendingAutoReload: DispatchWorkItem?

    private init() {
        ensureConfigExists()
        loadParsed()       // silent load — no notification on init
        migrateIfNeeded()
        startWatchingConfig()
    }

    // MARK: - Typed accessors (all read from `parsed`)

    var fontFamily: String { parsed["font-family"] ?? "MesloLGSNerdFont-Regular" }

    var fontSize: CGFloat {
        guard let s = parsed["font-size"], let v = Double(s) else { return 13 }
        return CGFloat(max(8, min(36, v)))
    }

    var colorScheme: Theme {
        guard let s = parsed["theme"] else { return .defaultTheme }
        return Theme.named(s) ?? .defaultTheme
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
        guard let s = parsed["width"], let v = Double(s) else { return 1000 }
        return CGFloat(max(300, v))
    }

    /// Panel height in points, read from config.
    /// 0 (or a missing key) means "use the 40 % of screen-height default".
    var panelHeight: CGFloat {
        guard let s = parsed["height"], let v = Double(s), v > 0 else { return 0 }
        return CGFloat(max(150, v))
    }

    /// Inner padding in points applied between the panel edges and the
    /// terminal view. Range: 0–40.
    var terminalPadding: CGFloat {
        guard let s = parsed["terminal-padding"], let v = Double(s) else { return 0 }
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

    /// Edge the tab bar sits on when two or more tabs are open:
    /// "top" or "bottom". Default: "bottom".
    var tabPosition: String {
        let s = (parsed["tab-position"] ?? "bottom").lowercased()
        return ["top", "bottom"].contains(s) ? s : "bottom"
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

    /// Opens the config file in the user's default plain-text editor.
    /// `.conf` has no registered handler on macOS, so a plain `open(_:)`
    /// would show an app-picker dialog — instead resolve whichever app
    /// handles plain text (TextEdit as a last resort) and open with it
    /// explicitly.
    func openConfigFile() {
        let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open(
            [Self.configFile],
            withApplicationAt: editor,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Re-reads the config file and posts `didChangeNotification`.
    func reload() {
        loadParsed()
        notifyChanged()
    }

    // MARK: - Auto-reload on save

    /// Watches the config file and reloads automatically when it changes.
    /// Editors typically save atomically (write temp file, rename over the
    /// original), which swaps the inode — so on .rename/.delete the watch
    /// is re-established on the path.
    private func startWatchingConfig() {
        configWatcher?.cancel()
        configWatcher = nil

        let fd = open(Self.configFile.path, O_EVTONLY)
        guard fd >= 0 else {
            // File momentarily missing (mid-atomic-save or deleted) — retry.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startWatchingConfig()
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.scheduleAutoReload()
            if !source.data.intersection([.rename, .delete]).isEmpty {
                self.startWatchingConfig()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    /// Debounces bursts of file events (editors fire several per save) and
    /// posts `didChangeNotification` only when a value actually changed —
    /// our own writes and no-op saves stay silent.
    private func scheduleAutoReload() {
        pendingAutoReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let previous = self.parsed
            self.loadParsed()
            if self.parsed != previous {
                self.notifyChanged()
            }
        }
        pendingAutoReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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

    /// Current canonical config layout version. Bump when keys are added or
    /// the template changes; files without the matching marker are rewritten
    /// in canonical form (existing values preserved).
    private static let configFormat = 4

    /// All keys the template knows how to place. Anything else the user
    /// added by hand survives migration under an "Other" section.
    private static let knownKeys: Set<String> = [
        "font-family", "font-size",
        "theme", "opacity", "cursor-style", "cursor-blink",
        "shell", "scrollback",
        "width", "height", "terminal-padding", "notch-gap", "tab-position",
    ]

    /// Renders the config file in canonical order, taking each value from
    /// `values` when present and the documented default otherwise. Inline
    /// comments are aligned to a shared column for readability.
    private static func canonicalContent(values: [String: String]) -> String {
        let commentColumn = 28

        func line(_ key: String, _ def: String, _ comment: String? = nil) -> String {
            let kv = "\(key) = \(values[key] ?? def)"
            guard let comment else { return kv }
            let pad = String(repeating: " ", count: max(commentColumn - kv.count, 2))
            return kv + pad + "# " + comment
        }

        /// Theme names from the registry, wrapped into comment lines so the
        /// list never goes stale as themes are added.
        func themeListComment() -> String {
            var lines: [String] = []
            var current = "#   "
            for name in Theme.all.map(\.name) {
                let piece = current == "#   " ? name : ", " + name
                if current.count + piece.count > 70 {
                    lines.append(current + ",")
                    current = "#   " + name
                } else {
                    current += piece
                }
            }
            lines.append(current)
            return lines.joined(separator: "\n")
        }

        let defaultShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        var content = """
        # NotchTerm — ~/.config/notchterm/notchterm.conf
        # Edits apply automatically when you save this file.
        # config-format: \(configFormat) (do not remove this line)


        # ── Font ──────────────────────────────────────────────────────────
        # PostScript name of any installed monospace font. The bundled
        # default includes Nerd Font glyphs. Examples: Menlo, SF Mono,
        # JetBrainsMonoNerdFont-Regular (install from nerdfonts.com).

        \(line("font-family", "MesloLGSNerdFont-Regular"))
        \(line("font-size", "13", "points, 8–36"))


        # ── Appearance ────────────────────────────────────────────────────
        # theme: any of the built-in color schemes:
        \(themeListComment())

        \(line("theme", "Default"))
        \(line("opacity", "1.0", "0.1 – 1.0"))
        \(line("cursor-style", "block", "block | underline | bar"))
        \(line("cursor-blink", "false", "true | false"))


        # ── Terminal ──────────────────────────────────────────────────────

        \(line("shell", defaultShell, "full path to the shell executable"))
        \(line("scrollback", "10000", "lines kept in history (min 100)"))


        # ── Window ────────────────────────────────────────────────────────

        \(line("width", "1000", "points (min 300)"))
        \(line("height", "400", "points; 0 = 40% of screen height"))
        \(line("terminal-padding", "0", "inner inset, 0–40"))
        \(line("notch-gap", "0", "gap below the notch, 0–50"))
        \(line("tab-position", "bottom", "tab bar edge: top | bottom"))
        """

        let unknown = values
            .filter { !knownKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
        if !unknown.isEmpty {
            content += "\n\n\n# ── Other ─────────────────────────────────────────────────────────\n\n"
            content += unknown.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
        }
        return content + "\n"
    }

    /// Rewrites pre-`configFormat` files (including any from the old
    /// append-migration era) into the compact canonical layout. User values
    /// are preserved; user comments are not — the file header says so.
    private func migrateIfNeeded() {
        let url = Self.configFile
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard !original.contains("config-format: \(Self.configFormat)") else { return }

        do {
            try Self.canonicalContent(values: parsed)
                .write(to: url, atomically: true, encoding: .utf8)
            loadParsed()
            print("[NotchTerm] Config migrated to format \(Self.configFormat).")
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

        do {
            try Self.canonicalContent(values: [:])
                .write(to: Self.configFile, atomically: true, encoding: .utf8)
        } catch {
            print("[NotchTerm] Failed to write default config: \(error.localizedDescription)")
        }
    }

}
