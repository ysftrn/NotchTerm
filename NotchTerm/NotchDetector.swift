import AppKit

/// Information about a screen's hover-trigger zone.
struct NotchInfo {
    /// The screen this zone belongs to.
    let screen: NSScreen
    /// The hover-trigger rect in screen (Cocoa) coordinates: the physical
    /// notch when the screen has one, otherwise a phantom notch-sized zone
    /// centered at the top of the screen.
    let notchRect: CGRect
    /// The rect of the full menu bar row, in screen coordinates.
    let menuBarRect: CGRect
    /// Whether `notchRect` is a real hardware notch.
    let hasNotch: Bool
}

enum NotchDetector {
    /// Width of the phantom trigger zone on screens without a notch —
    /// roughly the width of a real MacBook notch.
    static let phantomNotchWidth: CGFloat = 180

    /// Fallback zone height when the menu bar height can't be derived
    /// (e.g. auto-hidden menu bar).
    static let fallbackMenuBarHeight: CGFloat = 24

    /// Returns trigger-zone info for every connected screen. Screens with a
    /// physical notch use it; all others get a phantom notch so the panel
    /// works on external monitors and non-notch Macs alike.
    static func detectAll() -> [NotchInfo] {
        NSScreen.screens.map { info(for: $0) }
    }

    /// Returns trigger-zone info for a specific screen (never nil — falls
    /// back to a phantom notch when the screen has no hardware notch).
    static func info(for screen: NSScreen) -> NotchInfo {
        let screenFrame = screen.frame
        let insets = screen.safeAreaInsets

        if insets.top > 0 {
            // auxiliaryTopLeftArea / auxiliaryTopRightArea are the menu bar
            // segments that flank the notch. Their absence means the notch
            // spans the full width, which shouldn't happen in practice but
            // we guard against it gracefully by falling through to phantom.
            let leftWidth  = screen.auxiliaryTopLeftArea?.width  ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            let notchWidth = screenFrame.width - leftWidth - rightWidth

            if notchWidth > 0 {
                // Cocoa coordinates: y increases upward; screen top is frame.maxY.
                let notchRect = CGRect(
                    x: screenFrame.minX + leftWidth,
                    y: screenFrame.maxY - insets.top,
                    width: notchWidth,
                    height: insets.top
                )
                let menuBarRect = CGRect(
                    x: screenFrame.minX,
                    y: screenFrame.maxY - insets.top,
                    width: screenFrame.width,
                    height: insets.top
                )
                return NotchInfo(screen: screen, notchRect: notchRect,
                                 menuBarRect: menuBarRect, hasNotch: true)
            }
        }

        // Phantom notch: a menu-bar-height strip centered at the top edge.
        // visibleFrame.maxY sits below the menu bar, so the difference is the
        // menu bar height; 0 (auto-hidden menu bar) falls back to a constant.
        var menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY
        if menuBarHeight <= 0 {
            menuBarHeight = fallbackMenuBarHeight
        }

        let notchRect = CGRect(
            x: screenFrame.midX - phantomNotchWidth / 2,
            y: screenFrame.maxY - menuBarHeight,
            width: phantomNotchWidth,
            height: menuBarHeight
        )
        let menuBarRect = CGRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - menuBarHeight,
            width: screenFrame.width,
            height: menuBarHeight
        )
        return NotchInfo(screen: screen, notchRect: notchRect,
                         menuBarRect: menuBarRect, hasNotch: false)
    }
}
