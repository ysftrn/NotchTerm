import AppKit

/// Hosts one or more terminal tabs inside the panel. Owns the rounded-corner
/// mask for the whole content area, the tab strip (visible only when two or
/// more tabs exist), and the active-tab bookkeeping. Each tab is a full
/// `TerminalContentView` with its own shell process; inactive tabs stay
/// hidden but their shells keep running, matching the panel's own
/// hide-without-killing philosophy.
final class TabContainerView: NSView {

    private(set) var tabs: [TerminalContentView] = []
    private(set) var activeIndex = 0

    /// Fired when the tab bar appears/disappears or moves edges, so the
    /// panel can shrink the resize-border grab zone on that edge.
    var onTabBarLayoutChange: (() -> Void)?

    private let tabBar = TabBarView()
    private let tabBarHeight: CGFloat = 30

    var activeContent: TerminalContentView? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    var isTabBarVisible: Bool { tabs.count > 1 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        tabBar.onSelect = { [weak self] index in self?.select(index: index) }
        tabBar.onNewTab = { [weak self] in self?.newTab() }
        addSubview(tabBar)

        // Initial tab. Its shell starts lazily on first panel show.
        addTab(startShell: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: Settings.didChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not supported")
    }

    @objc private func settingsDidChange() {
        needsLayout = true
        tabBar.needsDisplay = true
        onTabBarLayoutChange?()
    }

    // MARK: - Tab operations

    @discardableResult
    func newTab() -> TerminalContentView {
        let tab = addTab(startShell: true)
        select(index: tabs.count - 1)
        return tab
    }

    @discardableResult
    private func addTab(startShell: Bool) -> TerminalContentView {
        let tab = TerminalContentView(frame: bounds)
        // The container owns the rounded mask; a nested mask would round the
        // seam where the terminal meets the tab strip.
        tab.layer?.cornerRadius = 0
        tab.onProcessExit = { [weak self] exited in self?.handleProcessExit(exited) }
        tab.onTitleChange = { [weak self] _ in self?.refreshTabBar() }
        tabs.append(tab)
        addSubview(tab, positioned: .below, relativeTo: tabBar)
        if startShell {
            tab.startShellIfNeeded()
        }
        needsLayout = true
        refreshTabBar()
        onTabBarLayoutChange?()
        return tab
    }

    /// Cmd+W path: kills the shell and removes the tab. No-op with a single
    /// tab — the caller decides what "close" means then (hide the panel).
    func closeActiveTab() {
        guard tabs.count > 1, let tab = activeContent else { return }
        tab.onProcessExit = nil   // suppress the exit callback for this kill
        tab.shutdown()
        remove(tab)
    }

    /// Shell exited on its own (`exit`, Ctrl+D). Close the tab; if it is the
    /// last one, restart the shell in place so the panel never goes empty.
    private func handleProcessExit(_ tab: TerminalContentView) {
        if tabs.count > 1 {
            remove(tab)
        } else {
            tab.restartShell()
        }
    }

    private func remove(_ tab: TerminalContentView) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        tab.removeFromSuperview()
        if activeIndex >= tabs.count {
            activeIndex = max(0, tabs.count - 1)
        } else if index < activeIndex {
            activeIndex -= 1
        }
        needsLayout = true
        refreshTabBar()
        onTabBarLayoutChange?()
        focusActiveTab()
    }

    func select(index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else {
            focusActiveTab()
            return
        }
        activeIndex = index
        needsLayout = true
        refreshTabBar()
        focusActiveTab()
    }

    func selectNext()     { select(index: (activeIndex + 1) % max(tabs.count, 1)) }
    func selectPrevious() { select(index: (activeIndex - 1 + tabs.count) % max(tabs.count, 1)) }

    func focusActiveTab() {
        if let tab = activeContent {
            window?.makeFirstResponder(tab.terminalView)
        }
    }

    private func refreshTabBar() {
        tabBar.items = tabs.map(\.tabTitle)
        tabBar.activeIndex = activeIndex
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let showBar = isTabBarVisible
        tabBar.isHidden = !showBar

        var contentFrame = bounds
        if showBar {
            let barOnTop = Settings.shared.tabPosition == "top"
            let barY = barOnTop ? bounds.height - tabBarHeight : 0
            tabBar.frame = NSRect(x: 0, y: barY, width: bounds.width, height: tabBarHeight)
            contentFrame = NSRect(
                x: 0,
                y: barOnTop ? 0 : tabBarHeight,
                width: bounds.width,
                height: bounds.height - tabBarHeight
            )
        }
        for (index, tab) in tabs.enumerated() {
            tab.frame = contentFrame
            tab.isHidden = index != activeIndex
        }
    }
}

// MARK: - TabBarView

/// Slim, flat tab strip. Inactive area is a darkened version of the theme
/// background; the active tab is drawn in the terminal background color so
/// it reads as connected to the terminal surface.
final class TabBarView: NSView {

    var items: [String] = [] { didSet { needsDisplay = true } }
    var activeIndex = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private let plusZoneWidth: CGFloat = 32
    private let maxTabWidth: CGFloat = 200

    private func tabRect(at index: Int) -> NSRect {
        let available = bounds.width - plusZoneWidth
        let width = min(maxTabWidth, available / CGFloat(max(items.count, 1)))
        return NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
    }

    private var plusRect: NSRect {
        NSRect(x: bounds.width - plusZoneWidth, y: 0, width: plusZoneWidth, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = Settings.shared.colorScheme
        let bg = theme.background
        let srgb = bg.usingColorSpace(.sRGB) ?? bg
        let isLight = srgb.brightnessComponent > 0.5
        let strip = bg.blended(withFraction: isLight ? 0.08 : 0.3, of: .black) ?? bg

        strip.setFill()
        bounds.fill()

        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        for (index, title) in items.enumerated() {
            let rect = tabRect(at: index)
            let isActive = index == activeIndex

            if isActive {
                bg.setFill()
                rect.fill()
            } else if index != activeIndex - 1 {
                // Hairline separator on the right edge of inactive tabs.
                theme.foreground.withAlphaComponent(0.12).setFill()
                NSRect(x: rect.maxX - 0.5, y: 6, width: 0.5, height: rect.height - 12).fill()
            }

            let color = isActive
                ? theme.foreground
                : theme.foreground.withAlphaComponent(0.55)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            let text = NSAttributedString(string: title, attributes: attrs)
            let textHeight = text.size().height
            text.draw(in: NSRect(x: rect.minX + 10,
                                 y: rect.minY + (rect.height - textHeight) / 2,
                                 width: rect.width - 20,
                                 height: textHeight))
        }

        // "+" new-tab affordance.
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: theme.foreground.withAlphaComponent(0.6),
        ]
        let plus = NSAttributedString(string: "+", attributes: plusAttrs)
        let plusSize = plus.size()
        plus.draw(at: NSPoint(x: plusRect.midX - plusSize.width / 2,
                              y: plusRect.midY - plusSize.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if plusRect.contains(point) {
            onNewTab?()
            return
        }
        for index in items.indices where tabRect(at: index).contains(point) {
            onSelect?(index)
            return
        }
    }
}
