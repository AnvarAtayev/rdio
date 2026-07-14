import AppKit

/// Compact ⏮ ⏯ ⏭ row shown as a custom view inside the dropdown menu.
final class TransportMenuView: NSView {
    private let previousButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()

    init(target: AnyObject, previous: Selector, playPause: Selector, next: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        autoresizingMask = [.width]

        configure(previousButton, symbol: "backward.fill", target: target, action: previous, size: 13)
        configure(playPauseButton, symbol: "play.fill", target: target, action: playPause, size: 17)
        configure(nextButton, symbol: "forward.fill", target: target, action: next, size: 13)

        let stack = NSStackView(views: [previousButton, playPauseButton, nextButton])
        stack.orientation = .horizontal
        stack.spacing = 30
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
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

    private func configure(_ button: NSButton, symbol: String, target: AnyObject,
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
