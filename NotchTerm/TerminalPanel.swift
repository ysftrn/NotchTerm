import AppKit

/// A borderless, floating, resizable panel that appears directly below the notch.
/// Horizontal symmetry is enforced: both edges move equally when the user resizes
/// left or right, keeping the panel centered on the notch at all times.
final class TerminalPanel: NSPanel, NSWindowDelegate {

    static let defaultWidth: CGFloat       = 600
    static let defaultHeightRatio: CGFloat = 0.4
    static let minWidth: CGFloat           = 300
    static let minHeight: CGFloat          = 150

    static let panelDidResizeNotification = Notification.Name("NotchTermPanelDidResize")

    private static let animDuration: TimeInterval = 0.2

    private(set) var terminalContent: TerminalContentView?

    /// Transparent overlay that intercepts mouse events near the panel edges
    /// to widen the drag-to-resize hit zone.
    private let resizeBorder = ResizeBorderView(frame: .zero)

    private var notchCenterX: CGFloat = 0
    private var notchTopY: CGFloat    = 0

    /// Full-size frame; kept separately so it is still valid after a fade-hide
    /// sets alphaValue to 0 or any other transient state.
    private var storedTargetFrame: NSRect = .zero

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        delegate = self

        let terminal = TerminalContentView(frame: .zero)
        terminalContent = terminal
        contentView = terminal
        attachResizeBorder()
    }

    /// Pins the resize border on top of whichever view is the current
    /// contentView. Constraints become inactive when the border is removed
    /// from its previous superview, so we re-add and re-activate from
    /// scratch each time.
    private func attachResizeBorder() {
        guard let cv = contentView else { return }
        resizeBorder.removeFromSuperview()
        resizeBorder.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(resizeBorder, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            resizeBorder.topAnchor.constraint(equalTo: cv.topAnchor),
            resizeBorder.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            resizeBorder.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            resizeBorder.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
        ])
    }

    /// Called by ResizeBorderView when the user finishes a manual edge drag.
    /// Mirrors `windowDidEndLiveResize`: refreshes `storedTargetFrame` and
    /// posts the resize-finished notification so AppDelegate can re-anchor
    /// the dismiss-monitor hit zone.
    func didFinishCustomResize() {
        storedTargetFrame = constrained(frame)
        NotificationCenter.default.post(name: Self.panelDidResizeNotification, object: self)
    }

    // MARK: - Positioning

    func reposition(using notchInfo: NotchInfo) {
        let screen    = notchInfo.screen
        let notchRect = notchInfo.notchRect

        notchCenterX = notchRect.midX
        // Lower the panel-top anchor by `notchGap` so a configurable buffer
        // sits between the notch's bottom edge and the panel.
        notchTopY    = notchRect.minY - Settings.shared.notchGap

        let maxWidth  = screen.frame.width
        let maxHeight = screen.visibleFrame.height

        let storedH = Settings.shared.panelHeight   // from config `height =`; 0 = default
        let cfgW    = Settings.shared.panelWidth

        let width  = max(Self.minWidth,  min(cfgW, maxWidth))
        let height = storedH > 0
            ? max(Self.minHeight, min(storedH, maxHeight))
            : round(maxHeight * Self.defaultHeightRatio)

        storedTargetFrame = NSRect(
            x:      round(notchCenterX - width / 2),
            y:      notchTopY - height,
            width:  width,
            height: height
        )

        setFrame(storedTargetFrame, display: true)
        alphaValue = CGFloat(Settings.shared.opacity)
    }

    // MARK: - setFrame overrides

    private func constrained(_ frameRect: NSRect) -> NSRect {
        guard notchCenterX > 0 else { return frameRect }
        return NSRect(
            x:      round(notchCenterX - frameRect.width / 2),
            y:      notchTopY - frameRect.height,
            width:  frameRect.width,
            height: frameRect.height
        )
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(constrained(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(constrained(frameRect), display: flag, animate: animateFlag)
    }

    // setFrameOrigin can be called directly by AppKit (e.g. drag-to-move paths
    // or display-reconfiguration) and bypasses setFrame:display:. Re-route it
    // through the constrained setFrame so origin-only updates can't break
    // horizontal symmetry.
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrame(constrained(NSRect(origin: point, size: frame.size)), display: true)
    }

    // MARK: - Show / Hide

    /// Shows the panel with a fade-in animation.
    /// `completion` is called once the animation finishes.
    func showPanel(completion: (() -> Void)? = nil) {
        terminalContent?.startShellIfNeeded()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let targetAlpha = CGFloat(Settings.shared.opacity)
        alphaValue = 0
        super.setFrame(storedTargetFrame, display: false)
        makeKeyAndOrderFront(nil)
        terminalContent?.makeTerminalFirstResponder()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.animDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = targetAlpha
        } completionHandler: {
            completion?()
        }
    }

    /// Hides the panel with a fade-out animation.
    /// `completion` is called once the animation finishes.
    func hidePanel(completion: (() -> Void)? = nil) {
        let targetAlpha = CGFloat(Settings.shared.opacity)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.animDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
            self.alphaValue = targetAlpha
            completion?()
        }
    }

    // MARK: - NSWindowDelegate

    /// Final safety net: if any internal AppKit path slipped past the setFrame
    /// overrides during this resize tick, snap the frame back to a notch-centered
    /// rectangle before the user sees the asymmetry persist.
    func windowDidResize(_ notification: Notification) {
        let target = constrained(frame)
        if target != frame {
            super.setFrame(target, display: true)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        storedTargetFrame = constrained(frame)
        NotificationCenter.default.post(name: Self.panelDidResizeNotification, object: self)
    }

    // MARK: - NSPanel overrides

    override var canBecomeKey: Bool { true }
}
