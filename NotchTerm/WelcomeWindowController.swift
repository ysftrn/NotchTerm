import AppKit

// MARK: - WelcomeWindowController

final class WelcomeWindowController: NSWindowController, NSWindowDelegate {

    /// Called when the user clicks "Get Started" or closes the window via the X button.
    var onGetStarted: (() -> Void)?

    /// Guards against double-firing when both the button and windowWillClose trigger.
    private var didFinish = false

    private var desiredCenterX: CGFloat = 0

    convenience init(notchCenterX: CGFloat? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 490),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to NotchTerm"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self

        let content = WelcomeContentView()
        content.onGetStarted = { [weak self] in self?.finish() }
        window.contentView = content

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        desiredCenterX = notchCenterX ?? (screenFrame.origin.x + screenFrame.width / 2)
    }

    func show() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.enforceFrame()
        }
    }

    private func enforceFrame() {
        guard let w = window else { return }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let x = bounds.origin.x + (bounds.width - w.frame.width) / 2
        let y = bounds.origin.y + (bounds.height - w.frame.height) / 2
        w.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        window?.orderOut(nil)
        onGetStarted?()
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

// MARK: - WelcomeContentView

private final class WelcomeContentView: NSView {

    var onGetStarted: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    // MARK: Layout

    private func build() {
        let hPad: CGFloat = 40

        // App icon
        let iconView = NSImageView()
        iconView.image = NSImage(named: NSImage.applicationIconName)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageFrameStyle = .none
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 22
        iconView.layer?.shadowColor = NSColor(red: 0.6, green: 0.2, blue: 1.0, alpha: 1.0).cgColor
        iconView.layer?.shadowRadius = 20
        iconView.layer?.shadowOpacity = 0.8
        iconView.layer?.shadowOffset = .zero
        iconView.layer?.masksToBounds = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Title
        let titleLabel = label(
            "Welcome to NotchTerm",
            font: .systemFont(ofSize: 22, weight: .bold),
            alignment: .center
        )
        addSubview(titleLabel)

        // Description
        let descLabel = label(
            "A terminal that lives in your notch. Hover to show, move away to hide.",
            font: .systemFont(ofSize: 13),
            color: .secondaryLabelColor,
            alignment: .center
        )
        addSubview(descLabel)

        // Divider
        let div1 = divider()
        addSubview(div1)

        // Feature rows
        let f1 = featureRow("Any shell, any prompt — works out of the box")
        let f2 = featureRow("Always running in the background, ready when you are")
        let f3 = featureRow("Works across all Spaces and Mission Control")
        [f1, f2, f3].forEach { addSubview($0) }

        // Divider
        let div2 = divider()
        addSubview(div2)

        // Privacy section
        let privacyBox = privacySection()
        addSubview(privacyBox)

        // Get Started button
        let button = NSButton(title: "Get Started", target: self, action: #selector(getStartedTapped))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            // Icon: 80×80, centered, 32pt from top
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80),

            // Title: below icon
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),

            // Description: below title
            descLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            descLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            descLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),

            // First divider
            div1.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 20),
            div1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            div1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),

            // Feature rows
            f1.topAnchor.constraint(equalTo: div1.bottomAnchor, constant: 18),
            f1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            f1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),

            f2.topAnchor.constraint(equalTo: f1.bottomAnchor, constant: 10),
            f2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            f2.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),

            f3.topAnchor.constraint(equalTo: f2.bottomAnchor, constant: 10),
            f3.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            f3.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),

            // Second divider
            div2.topAnchor.constraint(equalTo: f3.bottomAnchor, constant: 18),
            div2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            div2.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),

            // Privacy section
            privacyBox.topAnchor.constraint(equalTo: div2.bottomAnchor, constant: 16),
            privacyBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            privacyBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),

            // Get Started button: centered, standard width, 24pt below privacy, 32pt above bottom
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.topAnchor.constraint(equalTo: privacyBox.bottomAnchor, constant: 24),
            button.widthAnchor.constraint(equalToConstant: 160),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
        ])
    }

    @objc private func getStartedTapped() {
        onGetStarted?()
    }

    // MARK: Helpers

    private func label(
        _ text: String,
        font: NSFont,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .left
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func featureRow(_ text: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let iconImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)

        let iconView = NSImageView()
        iconView.image = iconImage
        iconView.contentTintColor = .systemGreen
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let textField = label(text, font: .systemFont(ofSize: 13))

        row.addSubview(iconView)
        row.addSubview(textField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            textField.topAnchor.constraint(equalTo: row.topAnchor),
            textField.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        return row
    }

    private func privacySection() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = NSColor.separatorColor
        box.fillColor = NSColor.controlBackgroundColor
        box.cornerRadius = 8
        box.borderWidth = 1
        box.translatesAutoresizingMaskIntoConstraints = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let iconImage = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)

        let iconView = NSImageView()
        iconView.image = iconImage
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let primaryText = label(
            "NotchTerm requires Accessibility access to detect mouse movement over the notch.",
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )
        let secondaryText = label(
            "It does not record keystrokes, screen content, or any user data.",
            font: .systemFont(ofSize: 11),
            color: .tertiaryLabelColor
        )

        box.addSubview(iconView)
        box.addSubview(primaryText)
        box.addSubview(secondaryText)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            primaryText.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            primaryText.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            primaryText.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),

            secondaryText.leadingAnchor.constraint(equalTo: primaryText.leadingAnchor),
            secondaryText.trailingAnchor.constraint(equalTo: primaryText.trailingAnchor),
            secondaryText.topAnchor.constraint(equalTo: primaryText.bottomAnchor, constant: 3),
            secondaryText.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])

        return box
    }
}
