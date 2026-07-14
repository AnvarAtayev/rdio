import AppKit

/// The dropdown is a fixed width. Titles are truncated to fit it rather than
/// being allowed to stretch it: this row centres itself in its own bounds, so a
/// menu made wider by a long track title would leave the buttons off-centre.
enum MenuMetrics {
    /// What the menu measures, since nothing is allowed to exceed it. Enough for a
    /// ~150pt station name, which is what the stock list needs; longer ones ellipse.
    static let width: CGFloat = 256

    /// What AppKit spends on a row before the title starts, plus its trailing
    /// padding: 21 inset + 17 icon + 6 gap + 12 trailing.
    static let chrome: CGFloat = 56

    /// Reserved across *every* row for the widest key equivalent (⌘Q), even though
    /// only Settings and Quit have one. It is what sits to the right of a station
    /// name, and why the menu cannot be tighter than it is.
    static let shortcutColumn: CGFloat = 47

    /// All a title gets. Measured, not guessed — see `fitted(_:)`, which keeps
    /// titles inside it so none of them can widen the menu.
    static let textWidth: CGFloat = width - chrome - shortcutColumn

    /// The transport row's canvas. Deliberately narrower than the menu so it is
    /// never the thing setting the width; AppKit stretches it to fit on display.
    static let transportWidth: CGFloat = 180


    /// A blank stand-in for a row's icon. macOS supplies its own icon to items
    /// whose action it recognises — `terminate:`, `openSettings` — and draws it
    /// in a column that indents only the rows that have one. Giving the rest of
    /// the rows an empty icon keeps every title level.
    ///
    /// The playing station is marked with a tick *in this column* rather than
    /// with `state = .on`: a checked item opens AppKit's own state column, which
    /// is a second gutter to the left of this one — 13pt of indent on every row,
    /// there purely to hold a tick that only ever appears on one.
    static let iconGutter = NSImage(size: NSSize(width: 17, height: 16))

    /// An icon for a row macOS doesn't recognise, sized to match the ones it
    /// supplies itself so the column stays the width it already is.
    static func icon(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }
}

/// Compact ⏮ ⏯ ⏭ row shown as a custom view inside the dropdown menu.
final class TransportMenuView: NSView {
    private let previousButton = HoverImageButton()
    private let playPauseButton = HoverImageButton()
    private let shuffleButton = HoverImageButton()
    private let nextButton = HoverImageButton()

    init(target: AnyObject, previous: Selector, playPause: Selector, next: Selector, shuffle: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.transportWidth, height: 34))
        autoresizingMask = [.width]

        configure(previousButton, symbol: "backward.fill", target: target, action: previous, size: 13)
        configure(playPauseButton, symbol: "play.fill", target: target, action: playPause, size: 17)
        configure(nextButton, symbol: "forward.fill", target: target, action: next, size: 13)
        configure(shuffleButton, symbol: "shuffle", target: target, action: shuffle, size: 13)

        let stack = NSStackView(views: [previousButton, playPauseButton, nextButton, shuffleButton])
        stack.orientation = .horizontal
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // AppKit stretches a menu item's view to the full width of the menu, so
        // our own centre is the menu's centre. (`autoresizingMask` above is what
        // lets it: the view is born narrow and grows to fit.)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(isPlaying: Bool, canPlay: Bool, canSkip: Bool) {
        playPauseButton.image = symbolImage(isPlaying ? "pause.fill" : "play.fill", size: 17)
        playPauseButton.isEnabled = canPlay
        previousButton.isEnabled = canSkip
        nextButton.isEnabled = canSkip
    }

    private func configure(_ button: HoverImageButton, symbol: String, target: AnyObject,
                           action: Selector, size: CGFloat) {
        button.isBordered = false
        button.image = symbolImage(symbol, size: size)
        button.target = target
        button.action = action
        button.setButtonType(.momentaryChange)
    }

    private func symbolImage(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }
}

/// Borderless template-image button that brightens its tint on hover, so the
/// transport controls read as interactive like the SwiftUI sidebar buttons.
private final class HoverImageButton: NSButton {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = isEnabled ? .labelColor : .secondaryLabelColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }
}