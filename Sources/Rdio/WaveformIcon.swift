import AppKit

/// How the menu bar icon behaves while playing. Stored in UserDefaults.
enum IconStyle: String, CaseIterable, Identifiable {
    case spectrum, ripple, pulse, off

    var id: String { rawValue }

    static let styleKey = "IconStyle"
    static let barCountKey = "IconBarCount"
    static let nowPlayingTextKey = "ShowNowPlayingText"

    static var current: IconStyle {
        IconStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .spectrum
    }

    static var barCount: Int {
        max(3, min(8, UserDefaults.standard.integer(forKey: barCountKey)))
    }
}

/// Idle (not playing) menu bar icon choices, shown in Settings → Design.
enum IdleIcon {
    struct Option: Identifiable {
        let symbol: String
        let label: String
        var id: String { symbol }
    }

    static let key = "IdleIconSymbol"

    /// SF Symbol used when the user has never picked one. Kept as a constant so
    /// the registered default, SettingsModel fallback, and `current` all agree.
    static let defaultSymbol = "radio"

    static let options: [Option] = [
        Option(symbol: "dot.radiowaves.left.and.right", label: "Waves"),
        Option(symbol: "radio", label: "Radio"),
        Option(symbol: "antenna.radiowaves.left.and.right", label: "Antenna"),
        Option(symbol: "waveform", label: "Waveform"),
        Option(symbol: "music.note", label: "Note"),
        Option(symbol: "headphones", label: "Headphones"),
    ]

    static var current: String {
        UserDefaults.standard.string(forKey: key) ?? defaultSymbol
    }
}

/// Animates the status-item icon as dancing bars while radio plays, in the
/// style and bar count picked in Settings. Bars follow the live audio when
/// the tap delivers levels; otherwise they dance on a synthesized rhythm.
final class WaveformIconAnimator {
    private static let interval: TimeInterval = 1.0 / 15.0

    private weak var button: NSStatusBarButton?
    private let player: RadioPlayer
    private var timer: Timer?
    private var displayed: [Float] = []
    private var history: [Float] = []
    private var phase = 0.0

    init(button: NSStatusBarButton?, player: RadioPlayer) {
        self.button = button
        self.player = player
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the icon keeps dancing while the menu is open
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        displayed = []
        history = []
    }

    private func tick() {
        let style = IconStyle.current
        let barCount = IconStyle.barCount
        if displayed.count != barCount {
            displayed = .init(repeating: 0, count: barCount)
            history = .init(repeating: 0, count: barCount)
        }

        let (bands, isLive) = player.audioBands
        var targets = [Float](repeating: 0, count: barCount)

        if isLive, !bands.isEmpty {
            let overall = bands.reduce(0, +) / Float(bands.count)
            switch style {
            case .spectrum, .off:
                for i in 0..<barCount {
                    targets[i] = bands[min(bands.count - 1, i * bands.count / barCount)]
                }
            case .ripple:
                history.removeFirst()
                history.append(overall)
                targets = history
            case .pulse:
                let center = Float(barCount - 1) / 2
                for i in 0..<barCount {
                    let weight = 1 - 0.45 * abs(Float(i) - center) / max(center, 1)
                    targets[i] = overall * weight
                }
            }
        } else {
            phase += Self.interval
            for i in 0..<barCount {
                let value = 0.45 + 0.22 * sin(phase * 2.3 + Double(i) * 0.9)
                    + 0.16 * sin(phase * 5.1 + 1.4 + Double(i) * 0.55)
                targets[i] = Float(value + Double.random(in: -0.06...0.06))
            }
        }

        // snappy attack, slower decay
        for i in 0..<barCount {
            let target = min(max(targets[i], 0), 1)
            let rate: Float = target > displayed[i] ? 0.55 : 0.3
            displayed[i] += (target - displayed[i]) * rate
        }
        button?.image = Self.render(bars: displayed)
    }

    private static func render(bars: [Float]) -> NSImage {
        let barWidth: CGFloat = 2.4
        let gap: CGFloat = 1.5
        let size = NSSize(width: CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap,
                          height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            for (i, value) in bars.enumerated() {
                let height = 3 + CGFloat(value) * (rect.height - 3)
                let frame = NSRect(x: CGFloat(i) * (barWidth + gap),
                                   y: (rect.height - height) / 2,
                                   width: barWidth,
                                   height: height)
                NSBezierPath(roundedRect: frame, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
