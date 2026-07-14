import AVFoundation
import Foundation

/// Tries every station with a muted player and reports whether playback
/// actually starts, plus whether the audio tap delivers live levels (which
/// drive the waveform icon). Used by `make selftest`.
func runSelfTest(stations: [Station]) -> Never {
    print("Testing \(stations.count) stations (muted)…")
    var failures = 0

    for station in stations {
        let item = AVPlayerItem(url: station.url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.play()

        let deadline = Date(timeIntervalSinceNow: 15)
        while Date() < deadline,
              player.timeControlStatus != .playing,
              item.status != .failed {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        }

        if player.timeControlStatus == .playing {
            print("PASS  \(station.name)\(levelReport(for: item))")
        } else {
            failures += 1
            let reason = item.error?.localizedDescription ?? "timed out"
            print("FAIL  \(station.name) — \(reason)")
        }
        player.replaceCurrentItem(with: nil)
    }

    exit(failures == 0 ? 0 : 1)
}

/// Attaches a level tap to a playing item and samples it briefly.
private func levelReport(for item: AVPlayerItem) -> String {
    let meter = LevelMeter()
    let attached = DispatchSemaphore(value: 0)
    Task {
        await meter.attach(to: item)
        attached.signal()
    }
    let attachDeadline = Date(timeIntervalSinceNow: 3)
    while Date() < attachDeadline, attached.wait(timeout: .now()) == .timedOut {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
    }

    var peaks: [Float] = []
    var live = false
    let sampleDeadline = Date(timeIntervalSinceNow: 5)
    while Date() < sampleDeadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        let reading = meter.read()
        if reading.isLive {
            live = true
            if peaks.count != reading.bands.count {
                peaks = reading.bands
            } else {
                for i in 0..<peaks.count { peaks[i] = max(peaks[i], reading.bands[i]) }
            }
        }
    }
    if live {
        let bands = peaks.map { String(format: "%.2f", $0) }.joined(separator: " ")
        return "  [live spectrum, band peaks \(bands)]"
    }
    return "  [no tap levels — icon falls back to synthesized animation]"
}
