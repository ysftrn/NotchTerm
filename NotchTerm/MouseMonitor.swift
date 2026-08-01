import AppKit

/// Watches mouse-moved events and fires `onEnter`/`onExit` when the cursor
/// crosses into or out of a given rect (in Cocoa screen coordinates).
///
/// Supports both global (other app focused) and local (this app focused)
/// event monitors so tracking works regardless of which app is frontmost.
final class MouseMonitor {
    var onEnter: (() -> Void)?
    var onExit:  (() -> Void)?

    /// The primary rect to watch, in Cocoa screen coordinates (origin bottom-left).
    var watchRect: CGRect {
        didSet { isInside = false }
    }

    /// Additional rects that extend the "inside" zone. The cursor is considered
    /// inside when it falls within `watchRect` OR any rect in this array.
    /// Setting this does NOT reset `isInside` — do that explicitly if needed.
    var additionalWatchRects: [CGRect] = []

    /// When true, installs a local monitor in addition to the global one.
    let includesLocalMonitor: Bool

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isInside = false

    init(watchRect: CGRect, includesLocalMonitor: Bool = false) {
        self.watchRect = watchRect
        self.includesLocalMonitor = includesLocalMonitor
    }

    deinit {
        stop()
    }

    // MARK: - Control

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.evaluate()
        }

        if includesLocalMonitor, localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.evaluate()
                return event
            }
        }
    }

    /// Resets the inside/outside state without stopping the monitor.
    /// Call this when external logic has changed conditions (e.g. panel hidden)
    /// and the monitor should treat the next enter as fresh.
    func resetState() {
        isInside = false
    }

    var isRunning: Bool {
        globalMonitor != nil
    }

    func stop() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        isInside = false
    }

    // MARK: - Private

    private func evaluate() {
        let location = NSEvent.mouseLocation
        let inside = watchRect.contains(location)
            || additionalWatchRects.contains { $0.contains(location) }

        if inside, !isInside {
            isInside = true
            onEnter?()
        } else if !inside, isInside {
            isInside = false
            onExit?()
        }
    }
}
