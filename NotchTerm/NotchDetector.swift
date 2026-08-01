import AppKit

/// Information about the notch on a Mac display.
struct NotchInfo {
    /// The screen that contains the notch (always the built-in display).
    let screen: NSScreen
    /// The rect occupied by the notch itself, in screen (Cocoa) coordinates.
    let notchRect: CGRect
    /// The rect of the full menu bar row (notch + flanking areas), in screen coordinates.
    let menuBarRect: CGRect
}

enum NotchDetector {
    /// Returns notch info for the first notched screen found, or nil on non-notch hardware.
    static func detect() -> NotchInfo? {
        guard let screen = notchedScreen() else { return nil }
        return info(for: screen)
    }

    /// Returns notch info for a specific screen, or nil if that screen has no notch.
    static func info(for screen: NSScreen) -> NotchInfo? {
        let insets = screen.safeAreaInsets
        guard insets.top > 0 else { return nil }

        let screenFrame = screen.frame

        // auxiliaryTopLeftArea / auxiliaryTopRightArea are the menu bar segments
        // that flank the notch. Their absence means the notch spans the full width,
        // which shouldn't happen in practice but we guard against it gracefully.
        let leftWidth  = screen.auxiliaryTopLeftArea?.width  ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let notchWidth = screenFrame.width - leftWidth - rightWidth

        guard notchWidth > 0 else { return nil }

        // Cocoa coordinates: y increases upward; the top of the screen is frame.maxY.
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

        return NotchInfo(screen: screen, notchRect: notchRect, menuBarRect: menuBarRect)
    }

    // MARK: - Private

    private static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }
}
