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
        Option(symbol: "radio", label: "Radio"),  // `defaultSymbol` leads the row
        Option(symbol: "dot.radiowaves.left.and.right", label: "Waves"),
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
///
/// The drawing is optimised for the steady-state playback cost: 10 Hz is
/// visually identical to 15 Hz at this size, bars are filled as plain rects
/// (no per-bar `NSBezierPath`), and a single `NSImage` is reused via
/// `lockFocus`/`unlockFocus` — the previous per-tick allocator created 10
/// images + 80 paths every second.
final class WaveformIconAnimator {
    /// Animation cadence. 10 Hz is indistinguishable from 15 Hz at this scale;
    /// cutting the rate drops everything below by 33%.
    private static let interval: TimeInterval = 1.0 / 10.0

    /// Bar geometry, fixed for the menu bar.
    private static let barWidth: CGFloat = 2.4
    private static let gap: CGFloat = 1.5
    private static let canvasHeight: CGFloat = 16
    private static let minHeight: CGFloat = 3

    private weak var button: NSStatusBarButton?
    private let player: RadioPlayer
    private var timer: Timer?
    private var displayed: [Float] = []
    private var history: [Float] = []
    private var phase = 0.0

    /// Cached icon settings — refreshed via `updateSettings()` when the user
    /// changes them, never on every tick. Reads UserDefaults at most on
    /// settings change instead of 10×/sec.
    private var style: IconStyle = IconStyle.current
    private var barCount: Int = IconStyle.barCount

    /// Reused backing bitmap — reallocated only when `barCount` changes. The
    /// `NSImage` wrapper is cheap and created fresh each tick so the status
    /// button sees a new object reference and redraws (reusing one NSImage
    /// instance makes AppKit skip the redraw entirely).
    private var bitmapRep: NSBitmapImageRep?
    private var bitmapBarCount = -1

    init(button: NSStatusBarButton?, player: RadioPlayer) {
        self.button = button
        self.player = player
    }

    /// Re-reads the icon style and bar count from UserDefaults. Called by the
    /// app when Settings changes them — never inside `tick()`.
    func updateSettings() {
        style = IconStyle.current
        barCount = IconStyle.barCount
        if displayed.count != barCount {
            displayed = .init(repeating: 0, count: barCount)
            history = .init(repeating: 0, count: barCount)
        }
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

        button?.image = render(bars: displayed)
    }

    /// Draws bars as pills into a cached `NSBitmapImageRep`, then wraps it in a
    /// fresh lightweight `NSImage` so the status button sees a new object and
    /// redraws. The rep (the expensive allocation) is reused across ticks; only
    /// its pixels are repainted.
    private func render(bars: [Float]) -> NSImage {
        let count = bars.count
        let width = CGFloat(count) * Self.barWidth + CGFloat(max(count - 1, 0)) * Self.gap
        let rep = self.rep(for: count, pixelWidth: Int(ceil(width * 2)),
                           pixelHeight: Int(ceil(Self.canvasHeight * 2)))

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        // The rep's pixel dimensions are 2× the logical size; draw in logical
        // coords by scaling the current context.
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: 2, y: 2)

        // Erase the previous frame: in a bitmap rep, filling with clear composites
        // nothing over existing pixels, so bars would accumulate. `clear()` zeros
        // the area so each tick starts from a transparent canvas.
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: Self.canvasHeight))

        NSColor.black.setFill()
        for (i, value) in bars.enumerated() {
            let height = Self.minHeight + CGFloat(value) * (Self.canvasHeight - Self.minHeight)
            let frame = NSRect(x: CGFloat(i) * (Self.barWidth + Self.gap),
                               y: (Self.canvasHeight - height) / 2,
                               width: Self.barWidth, height: height)
            NSBezierPath(roundedRect: frame,
                         xRadius: Self.barWidth / 2,
                         yRadius: Self.barWidth / 2).fill()
        }

        let image = NSImage(size: NSSize(width: width, height: Self.canvasHeight))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// Returns the cached `NSBitmapImageRep` for the current bar count,
    /// rebuilding it only when `barCount` changes.
    private func rep(for count: Int, pixelWidth: Int, pixelHeight: Int) -> NSBitmapImageRep {
        if let rep = bitmapRep, bitmapBarCount == count { return rep }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                    bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0)!
        bitmapRep = rep
        bitmapBarCount = count
        return rep
    }
}