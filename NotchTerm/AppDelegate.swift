import AppKit
import CoreText
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private(set) var notchInfo: NotchInfo?
    private var notchTriggerMonitor: MouseMonitor?
    private var panelDismissMonitor: MouseMonitor?
    private var menuShortcutMonitor: Any?
    private var terminalPanel: TerminalPanel?
    private var accessibilityPollTimer: Timer?
    private var welcomeWindowController: WelcomeWindowController?
    private var isPanelVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        setupStatusItem()
        detectNotch()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: Settings.didChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResize),
            name: TerminalPanel.panelDidResizeNotification,
            object: nil
        )

        if UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            ensureAccessibilityAccess()
        } else {
            showWelcomeWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Font registration

    /// Registers fonts bundled inside the app (e.g. MesloLGSNerdFont-Regular.ttf)
    /// with Core Text so they are available by PostScript name before any
    /// TerminalContentView is created.
    private func registerBundledFonts() {
        let fontNames = ["MesloLGSNerdFont-Regular"]
        for name in fontNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("[NotchTerm] Bundled font not found: \(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if registered {
                print("[NotchTerm] Registered bundled font: \(name)")
            } else if let err = error?.takeRetainedValue() {
                print("[NotchTerm] Font registration failed for \(name): \(err)")
            }
        }
    }

    // MARK: - Notch detection

    private func detectNotch() {
        notchInfo = NotchDetector.detect()

        if let info = notchInfo {
            print("[NotchTerm] Notch detected on screen '\(info.screen.localizedName)'")
            print("[NotchTerm]   notchRect   : \(info.notchRect)")
            print("[NotchTerm]   menuBarRect : \(info.menuBarRect)")
            setupTerminalPanel(notchInfo: info)
            if AXIsProcessTrusted() {
                startNotchTriggerMonitor(notchRect: info.notchRect)
            }
        } else {
            print("[NotchTerm] No notch detected — running on non-notch hardware or external display only.")
            notchTriggerMonitor?.stop()
            notchTriggerMonitor = nil
            panelDismissMonitor?.stop()
            panelDismissMonitor = nil
            isPanelVisible = false
            terminalPanel?.hidePanel()
            terminalPanel = nil
        }
    }

    @objc private func screensDidChange() {
        detectNotch()
    }

    @objc private func settingsDidChange() {
        if let info = notchInfo {
            terminalPanel?.reposition(using: info)
        }
    }

    @objc private func panelDidResize() {
        if isPanelVisible {
            startPanelDismissMonitor()
        }
    }

    // MARK: - Terminal panel

    private func setupTerminalPanel(notchInfo: NotchInfo) {
        if terminalPanel == nil {
            terminalPanel = TerminalPanel()
        }
        terminalPanel?.reposition(using: notchInfo)
    }

    // MARK: - Mouse monitors

    /// Global + local monitor on the notch rect. Fires onEnter to show the panel.
    /// Needs both monitors because after hidePanel() NotchTerm may still be
    /// the frontmost app, and a global-only monitor won't fire in that case.
    private func startNotchTriggerMonitor(notchRect: CGRect) {
        // Extend 5 pts past the screen's top edge so the cursor hitting the
        // physical boundary doesn't miss the notch region.
        var watchRect = notchRect
        watchRect.size.height += 5

        if let existing = notchTriggerMonitor {
            existing.watchRect = watchRect
            return
        }

        let monitor = MouseMonitor(watchRect: watchRect, includesLocalMonitor: true)
        monitor.onEnter = { [weak self] in self?.showTerminalPanel() }
        monitor.start()
        notchTriggerMonitor = monitor
    }

    /// Global + local monitor covering the panel frame and the notch rect as two
    /// independent zones. The cursor must leave BOTH before hide fires, giving a
    /// non-rectangular boundary that matches the actual notch width at the top.
    private func startPanelDismissMonitor() {
        guard let panel = terminalPanel, let info = notchInfo else { return }

        // Extend notch 5 pts upward so hitting the physical screen edge is safe.
        var notchRect = info.notchRect
        notchRect.size.height += 5

        // Expand panel frame by 20 pts on all sides so grabbing a resize handle
        // or moving just outside the edge doesn't immediately dismiss the panel.
        // The top inset additionally covers `notchGap` so the cursor traveling
        // from the notch down to the panel never crosses an uncovered strip.
        let topPad  = max(20, Settings.shared.notchGap + 5)
        let pf = panel.frame
        let dismissRect = NSRect(x: pf.minX - 20,
                                 y: pf.minY - 20,
                                 width: pf.width + 40,
                                 height: pf.height + 20 + topPad)

        if let existing = panelDismissMonitor {
            existing.watchRect = dismissRect
            existing.additionalWatchRects = [notchRect]
            return
        }

        let monitor = MouseMonitor(watchRect: dismissRect, includesLocalMonitor: true)
        monitor.additionalWatchRects = [notchRect]
        monitor.onExit = { [weak self] in self?.hideTerminalPanel() }
        monitor.start()
        panelDismissMonitor = monitor
    }

    private func stopPanelDismissMonitor() {
        panelDismissMonitor?.stop()
        panelDismissMonitor = nil
    }

    private func showTerminalPanel() {
        guard !isPanelVisible else { return }
        isPanelVisible = true
        // Stop the dismiss monitor before the animation starts so expanding
        // frames don't fire false exit events mid-animation.
        stopPanelDismissMonitor()
        startMenuShortcutMonitor()
        terminalPanel?.showPanel { [weak self] in
            // Re-arm the dismiss monitor only after the panel has fully expanded.
            self?.startPanelDismissMonitor()
        }
    }

    private func hideTerminalPanel() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        // Stop monitors immediately — don't wait for animation to finish.
        stopPanelDismissMonitor()
        stopMenuShortcutMonitor()
        terminalPanel?.hidePanel { [weak self] in
            // Reset trigger monitor only after panel is fully hidden so a hover
            // during the contraction animation can't re-open prematurely.
            self?.notchTriggerMonitor?.resetState()
        }
    }

    // MARK: - Menu shortcut monitor

    /// Dispatches status-menu key equivalents (Cmd+Q, Cmd+R, Cmd+, …) and
    /// tab shortcuts while the panel is visible, without requiring the user
    /// to open the menu first. Reads key equivalents directly from the menu
    /// so this stays in sync with any future menu changes. Active only while
    /// the panel is shown.
    private func startMenuShortcutMonitor() {
        guard menuShortcutMonitor == nil else { return }
        menuShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let pressed = event.modifierFlags.intersection([.command, .option, .shift, .control])
            let tabs = self.terminalPanel?.tabContainer

            // Ctrl+Tab / Ctrl+Shift+Tab: cycle tabs (keyCode 48 = Tab).
            if event.keyCode == 48, pressed == .control || pressed == [.control, .shift] {
                if pressed.contains(.shift) {
                    tabs?.selectPrevious()
                } else {
                    tabs?.selectNext()
                }
                return nil
            }

            guard pressed.contains(.command),
                  let menu = self.statusItem?.menu
            else { return event }

            // Handle shortcuts that have no menu item.
            if pressed == .command {
                switch chars {
                case "t":
                    tabs?.newTab()
                    return nil
                case "w":
                    // Close the tab; with a single tab, "close" hides the panel.
                    if let tabs, tabs.tabs.count > 1 {
                        tabs.closeActiveTab()
                    } else {
                        self.hideTerminalPanel()
                    }
                    return nil
                case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                    if let n = Int(chars) {
                        tabs?.select(index: n - 1)
                    }
                    return nil
                case "k":
                    self.terminalPanel?.terminalContent?.clearTerminal()
                    return nil
                case "v":
                    if let text = NSPasteboard.general.string(forType: .string) {
                        self.terminalPanel?.terminalContent?.terminalView.send(txt: text)
                    }
                    return nil
                case "c":
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: self.terminalPanel?.terminalContent?.terminalView, from: nil)
                    return nil
                default:
                    break
                }
            }

            for item in menu.items where !item.keyEquivalent.isEmpty {
                guard item.keyEquivalent.lowercased() == chars,
                      item.keyEquivalentModifierMask == pressed,
                      let action = item.action
                else { continue }
                NSApp.sendAction(action, to: item.target, from: item)
                return nil  // consumed
            }
            return event
        }
    }

    private func stopMenuShortcutMonitor() {
        if let m = menuShortcutMonitor {
            NSEvent.removeMonitor(m)
            menuShortcutMonitor = nil
        }
    }

    // MARK: - Welcome window

    private func showWelcomeWindow() {
        let wc = WelcomeWindowController(notchCenterX: notchInfo?.notchRect.midX)
        wc.onGetStarted = { [weak self] in
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            self?.welcomeWindowController = nil
            self?.ensureAccessibilityAccess()
        }
        wc.show()
        welcomeWindowController = wc
    }

    // MARK: - Accessibility permission

    private func ensureAccessibilityAccess() {
        if AXIsProcessTrusted() {
            print("[NotchTerm] Accessibility access granted.")
            return
        }

        print("[NotchTerm] Accessibility access not granted — showing prompt.")
        showAccessibilityAlert()
        startAccessibilityPolling()
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "NotchTerm needs Accessibility access to detect mouse movement over the notch area. Please grant access in System Settings, then the app will activate automatically."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url = url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Polls `AXIsProcessTrusted()` every 2 seconds until access is granted,
    /// then starts the mouse monitor.
    private func startAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityPollTimer = nil
                print("[NotchTerm] Accessibility access granted (detected via polling).")
                if let info = self?.notchInfo {
                    self?.startNotchTriggerMonitor(notchRect: info.notchRect)
                }
            }
        }
    }

    // MARK: - Status bar

    /// Draws ">_" in a monospaced font and marks the image as a template so
    /// AppKit automatically inverts it for dark/light menu bar and highlight states.
    private func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let str = NSAttributedString(string: ">_", attributes: attrs)
            let strSize = str.size()
            let origin = NSPoint(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2
            )
            str.draw(at: origin)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = makeMenuBarIcon()

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchTerm", action: #selector(confirmQuit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    // MARK: - Launch at Login

    /// Refreshes the "Launch at Login" checkmark right before the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let item = menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) }) {
            item.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to quit NotchTerm?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    @objc private func openConfig() {
        Settings.shared.openConfigFile()
    }

    @objc private func reloadConfig() {
        Settings.shared.reload()
    }
}
