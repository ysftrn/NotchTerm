import AppKit
import SwiftTerm

/// Wraps a SwiftTerm `LocalProcessTerminalView` and manages the shell lifecycle.
/// This view is intended to be set as the `contentView` of `TerminalPanel`.
final class TerminalContentView: NSView, LocalProcessTerminalViewDelegate {

    private(set) var terminalView: LocalProcessTerminalView
    private var hasStartedProcess = false
    private var isRespawning = false
    private let visualEffect = NSVisualEffectView()
    private weak var terminalScroller: NSScroller?
    private var scrollerObservations: [NSKeyValueObservation] = []

    /// Called when the shell exits on its own (`exit`, Ctrl+D). When set —
    /// tab mode — the owner decides whether to close the tab or restart.
    /// When nil, the shell restarts in place (legacy single-view behavior).
    var onProcessExit: ((TerminalContentView) -> Void)?

    /// Called whenever `tabTitle` changes.
    var onTitleChange: ((TerminalContentView) -> Void)?

    /// Title for the tab strip: the shell's title escape sequence when one
    /// has been received, otherwise the shell's basename.
    private(set) var tabTitle: String = (Settings.shared.shell as NSString).lastPathComponent {
        didSet { if oldValue != tabTitle { onTitleChange?(self) } }
    }

    // Terminal-view padding constraints — `constant` is updated from
    // Settings.terminalPadding so the inset can be tuned live.
    private var terminalLeadingC: NSLayoutConstraint!
    private var terminalTrailingC: NSLayoutConstraint!
    private var terminalBottomC: NSLayoutConstraint!
    private var terminalTopC: NSLayoutConstraint!

    override init(frame: CGRect) {
        terminalView = LocalProcessTerminalView(frame: frame)
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        // Visual effect view sits behind the terminal. The parent's masksToBounds
        // clips both subviews at the rounded corners.
        visualEffect.blendingMode = .behindWindow
        // .hudWindow is the semantic replacement for the deprecated .dark
        // material — same dark vibrant appearance, future-proof.
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffect)

        terminalView.processDelegate = self
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        // Pass Option+key combinations through as characters (e.g. Option+Q = '@'
        // on Turkish keyboards) rather than treating Option as a Meta/ESC prefix.
        terminalView.optionAsMetaKey = false

        addSubview(terminalView)
        setupScrollerAutoHide()

        let pad = Settings.shared.terminalPadding
        terminalTopC      = terminalView.topAnchor.constraint(equalTo: topAnchor,               constant: pad)
        terminalBottomC   = terminalView.bottomAnchor.constraint(equalTo: bottomAnchor,         constant: -pad)
        terminalLeadingC  = terminalView.leadingAnchor.constraint(equalTo: leadingAnchor,       constant: pad)
        terminalTrailingC = terminalView.trailingAnchor.constraint(equalTo: trailingAnchor,     constant: -pad)

        // applySettings() reads the padding constraints, so it must run after
        // they're constructed.
        applySettings()

        NSLayoutConstraint.activate([
            visualEffect.topAnchor.constraint(equalTo: topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: trailingAnchor),

            terminalTopC,
            terminalBottomC,
            terminalLeadingC,
            terminalTrailingC,
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: Settings.didChangeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // Display sleep also breaks the DispatchIO read loop; recover on screen wake too.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not supported")
    }

    // MARK: - Scroller auto-hide

    /// SwiftTerm pins a legacy-style NSScroller to the terminal's right edge
    /// that is always drawn. Locate it and drive its visibility via KVO on
    /// the properties SwiftTerm's `updateScroller()` writes: fade in only
    /// while scrolled up into history, fade out at the live bottom (or when
    /// there is nothing to scroll — fresh screen, alternate buffer).
    private func setupScrollerAutoHide() {
        guard terminalScroller == nil,
              let scroller = terminalView.subviews.compactMap({ $0 as? NSScroller }).first
        else { return }
        terminalScroller = scroller
        scroller.scrollerStyle = .overlay
        scroller.alphaValue = 0
        scrollerObservations = [
            scroller.observe(\.isEnabled) { [weak self] _, _ in self?.updateScrollerVisibility() },
            scroller.observe(\.doubleValue) { [weak self] _, _ in self?.updateScrollerVisibility() },
            scroller.observe(\.knobProportion) { [weak self] _, _ in self?.updateScrollerVisibility() },
        ]
        updateScrollerVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Fallback in case the scroller didn't exist yet during init.
        setupScrollerAutoHide()
    }

    private func updateScrollerVisibility() {
        guard let scroller = terminalScroller else { return }
        let scrolledIntoHistory = scroller.isEnabled && scroller.doubleValue < 0.999
        let target: CGFloat = scrolledIntoHistory ? 1 : 0
        guard scroller.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            scroller.animator().alphaValue = target
        }
    }

    // MARK: - Settings

    @objc private func settingsDidChange() {
        applySettings()
    }

    private func applySettings() {
        let theme = Settings.shared.colorScheme
        terminalView.installColors(theme.swiftTermAnsi)
        terminalView.nativeBackgroundColor = theme.background
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.caretColor = theme.cursor
        // Selection colors ship at full opacity (Windows Terminal convention);
        // SwiftTerm paints them opaque, so knock them down or they'd hide text.
        terminalView.selectedTextBackgroundColor = theme.selection.withAlphaComponent(0.4)
        terminalView.font = Settings.shared.resolvedFont()
        terminalView.needsDisplay = true

        let pad = Settings.shared.terminalPadding
        terminalTopC.constant      = pad
        terminalBottomC.constant   = -pad
        terminalLeadingC.constant  = pad
        terminalTrailingC.constant = -pad

        let cursorStyle: CursorStyle
        switch (Settings.shared.cursorShape, Settings.shared.cursorBlink) {
        case ("underline", false): cursorStyle = .steadyUnderline
        case ("underline", true):  cursorStyle = .blinkUnderline
        case ("bar",       false): cursorStyle = .steadyBar
        case ("bar",       true):  cursorStyle = .blinkBar
        case (_,           true):  cursorStyle = .blinkBlock
        default:                   cursorStyle = .steadyBlock
        }
        let terminal = terminalView.getTerminal()
        terminal.setCursorStyle(cursorStyle)
        terminal.changeScrollback(Settings.shared.scrollback)
    }

    // MARK: - Sleep/wake recovery

    @objc private func systemDidWake() {
        // Delay briefly to let the system fully stabilize after wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkProcessHealth()
        }
    }

    private func checkProcessHealth() {
        // Skip if a respawn is already in progress to prevent double-respawn races.
        guard hasStartedProcess, !isRespawning, let process = terminalView.process else { return }

        let pid = process.shellPid

        // Process already marked as not running — processTerminated may have
        // been lost during sleep.
        if !process.running {
            respawnShell()
            return
        }

        // Process marked running but actually dead (kernel killed it during sleep).
        if pid > 0, kill(pid, 0) != 0 {
            // Don't call terminate() here — respawnShell() handles cleanup internally.
            respawnShell()
            return
        }

        // PTY file descriptor closed (EOF during sleep) but process still alive —
        // the DispatchIO read chain is broken and can't recover.
        if process.childfd == -1 {
            // Don't call terminate() here — respawnShell() handles cleanup internally.
            respawnShell()
            return
        }

        // Process alive and PTY open — send SIGWINCH to nudge a redraw.
        if pid > 0 {
            kill(pid, SIGWINCH)
        }
    }

    // MARK: - Shell process

    /// Starts the shell process if it hasn't been started yet.
    func startShellIfNeeded() {
        guard !hasStartedProcess else { return }
        hasStartedProcess = true
        startShell()
    }

    private func startShell() {
        let shell = Settings.shared.shell

        // Build environment: inherit current process environment, override TERM.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // TERM_PROGRAM/TERM_PROGRAM_VERSION is the de facto convention other
        // terminals (Ghostty, iTerm2, WezTerm, VSCode, …) use to identify
        // themselves to apps running inside them (e.g. claude-code's status line).
        env["TERM_PROGRAM"] = "NotchTerm"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        // Ensure LANG is set for proper UTF-8 support.
        if env["LANG"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }

        let envStrings = env.map { "\($0.key)=\($0.value)" }

        let home = env["HOME"] ?? NSHomeDirectory()

        // Pass shell as -shellname for argv[0] so it starts as a login shell.
        let shellBasename = (shell as NSString).lastPathComponent
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: envStrings,
            execName: "-\(shellBasename)",
            currentDirectory: home
        )

    }

    /// Restarts the shell in place — used for the last remaining tab so the
    /// panel never goes empty.
    func restartShell() {
        respawnShell()
    }

    /// Kills the shell process. Used when a tab is closed explicitly; the
    /// caller is responsible for removing the view afterwards.
    func shutdown() {
        terminalView.terminate()
    }

    /// Respawns the shell after it has exited (e.g. user typed `exit` or Ctrl+D).
    /// Force-terminates any lingering PTY/DispatchIO state before starting a new
    /// process — without this, a Ctrl+D respawn occasionally produced a frozen
    /// session because SwiftTerm's previous read chain was still active when the
    /// new shell started, swallowing input. The `isRespawning` guard prevents
    /// re-entry if `terminate()` synchronously redelivers `processTerminated`.
    private func respawnShell() {
        guard !isRespawning else { return }
        isRespawning = true

        terminalView.terminate()
        terminalView.getTerminal().resetToInitialState()
        hasStartedProcess = false

        // Defer the restart one runloop tick so SwiftTerm can fully tear down
        // the previous LocalProcess before a new one is spawned.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startShellIfNeeded()
            self.isRespawning = false
        }
    }

    // MARK: - Focus

    /// Transfers first responder status to the inner terminal view.
    func makeTerminalFirstResponder() {
        window?.makeFirstResponder(terminalView)
    }

    // MARK: - Clear screen

    /// Sends Ctrl+L to the shell process, clearing the visible screen
    /// and redrawing the prompt — equivalent to pressing Ctrl+L in the terminal.
    func clearTerminal() {
        terminalView.send(txt: "\u{0c}")
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // No action needed — SwiftTerm handles pty resize internally.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            tabTitle = trimmed
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Could track working directory in the future.
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Handle on the next runloop tick to avoid re-entry issues.
        // Guard against a stale callback arriving after checkProcessHealth() already
        // started a respawn (double-respawn would kill the newly spawned shell).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRespawning else { return }
            if let handler = self.onProcessExit {
                handler(self)
            } else {
                self.respawnShell()
            }
        }
    }
}
