import AppKit

/// Transparent overlay that widens the drag-to-resize hit zone of the
/// borderless TerminalPanel. The view fills the panel's contentView; only
/// points within `edgeWidth` of an edge (or `cornerSize` of a corner) are
/// hit-tested as belonging to it — every other point falls through to the
/// terminal beneath. Resizing is performed manually via setFrame on the
/// host window, since AppKit's `.resizable` hit zone is only a few pixels.
final class ResizeBorderView: NSView {

    /// Width of the edge-only resize zones. Corners get `cornerSize` instead.
    var edgeWidth: CGFloat = 14
    /// Side length of the L-shaped corner resize zones. Should be larger
    /// than `edgeWidth` so corners are easier to grab than straight edges.
    var cornerSize: CGFloat = 20

    private enum Edge {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return edge(at: local) != nil ? self : nil
    }

    private func edge(at p: NSPoint) -> Edge? {
        let b = bounds
        let nearLeft   = p.x <= edgeWidth
        let nearRight  = p.x >= b.width  - edgeWidth
        let nearBottom = p.y <= edgeWidth
        let nearTop    = p.y >= b.height - edgeWidth

        let inCornerLeft   = p.x <= cornerSize
        let inCornerRight  = p.x >= b.width  - cornerSize
        let inCornerBottom = p.y <= cornerSize
        let inCornerTop    = p.y >= b.height - cornerSize

        if inCornerTop    && inCornerLeft  { return .topLeft }
        if inCornerTop    && inCornerRight { return .topRight }
        if inCornerBottom && inCornerLeft  { return .bottomLeft }
        if inCornerBottom && inCornerRight { return .bottomRight }
        if nearTop    { return .top }
        if nearBottom { return .bottom }
        if nearLeft   { return .left }
        if nearRight  { return .right }
        return nil
    }

    override func resetCursorRects() {
        let b = bounds
        let cornerInset = cornerSize
        let edgeInset = edgeWidth
        // Horizontal edges (top/bottom) — exclude corner regions
        let topEdge = NSRect(x: cornerInset, y: b.height - edgeInset,
                             width: max(0, b.width - cornerInset * 2), height: edgeInset)
        let bottomEdge = NSRect(x: cornerInset, y: 0,
                                width: max(0, b.width - cornerInset * 2), height: edgeInset)
        addCursorRect(topEdge,    cursor: .resizeUpDown)
        addCursorRect(bottomEdge, cursor: .resizeUpDown)
        // Vertical edges (left/right) — exclude corner regions
        let leftEdge = NSRect(x: 0, y: cornerInset,
                              width: edgeInset, height: max(0, b.height - cornerInset * 2))
        let rightEdge = NSRect(x: b.width - edgeInset, y: cornerInset,
                               width: edgeInset, height: max(0, b.height - cornerInset * 2))
        addCursorRect(leftEdge,  cursor: .resizeLeftRight)
        addCursorRect(rightEdge, cursor: .resizeLeftRight)
        // Corners fall back to the closer of the two edge cursors. AppKit
        // doesn't expose the diagonal resize cursors as a public API, so
        // matching either edge's cursor reads as cleaner than crosshair.
        let tl = NSRect(x: 0, y: b.height - cornerInset, width: cornerInset, height: cornerInset)
        let tr = NSRect(x: b.width - cornerInset, y: b.height - cornerInset,
                        width: cornerInset, height: cornerInset)
        let bl = NSRect(x: 0, y: 0, width: cornerInset, height: cornerInset)
        let br = NSRect(x: b.width - cornerInset, y: 0, width: cornerInset, height: cornerInset)
        for r in [tl, tr, bl, br] {
            addCursorRect(r, cursor: .crosshair)
        }
    }

    // Custom drag-resize loop. AppKit's native resize sets `inLiveResize` and
    // runs in `.eventTracking` mode, which lets subviews opt into cheaper
    // drawing paths. A borderless panel with a custom hit zone never enters
    // that path through `mouseDragged` callbacks, so events queue behind the
    // main runloop and drags feel laggy. This pulls events directly with
    // `nextEvent(matching:)` — the same pattern AppKit uses internally — so
    // resize ticks land at input rate. Shadow rendering is the other big
    // per-frame cost; we drop it for the duration of the drag and restore
    // via `invalidateShadow()` once the user lets go.
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let edge = edge(at: local), let panel = window as? TerminalPanel else { return }

        let initialFrame = panel.frame
        let initialMouse = NSEvent.mouseLocation
        let prevShadow = panel.hasShadow
        panel.hasShadow = false

        trackingLoop: while true {
            guard let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                             until: .distantFuture,
                                             inMode: .eventTracking,
                                             dequeue: true) else { break }
            if next.type == .leftMouseUp { break trackingLoop }

            let cur = NSEvent.mouseLocation
            let dx = cur.x - initialMouse.x
            let dy = cur.y - initialMouse.y

            var newW = initialFrame.width
            var newH = initialFrame.height
            switch edge {
            case .left:        newW = initialFrame.width - dx
            case .right:       newW = initialFrame.width + dx
            case .top:         newH = initialFrame.height + dy
            case .bottom:      newH = initialFrame.height - dy
            case .topLeft:     newW = initialFrame.width - dx; newH = initialFrame.height + dy
            case .topRight:    newW = initialFrame.width + dx; newH = initialFrame.height + dy
            case .bottomLeft:  newW = initialFrame.width - dx; newH = initialFrame.height - dy
            case .bottomRight: newW = initialFrame.width + dx; newH = initialFrame.height - dy
            }

            newW = max(TerminalPanel.minWidth,  newW)
            newH = max(TerminalPanel.minHeight, newH)

            // TerminalPanel.setFrame override re-centers on the notch, so
            // origin is irrelevant here.
            let rect = NSRect(origin: initialFrame.origin,
                              size: NSSize(width: newW, height: newH))
            panel.setFrame(rect, display: true)
        }

        panel.hasShadow = prevShadow
        if prevShadow { panel.invalidateShadow() }
        panel.didFinishCustomResize()
    }
}
