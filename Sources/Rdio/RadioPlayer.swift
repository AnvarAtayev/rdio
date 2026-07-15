import AVFoundation
import Foundation
import MediaPlayer

enum PlayerState: Equatable {
    case stopped
    case connecting(Station)
    case playing(Station)
    case failed(Station)
}

/// Streams internet radio with AVPlayer and mirrors playback state to the
/// system now-playing controls (media keys, Control Center).
final class RadioPlayer: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let player = AVPlayer()
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private let levelMeter = LevelMeter()

    private(set) var state: PlayerState = .stopped
    private(set) var currentStation: Station?
    private(set) var trackTitle: String?

    /// Distinguishes a playback-state change (play/pause/stop) from a mere
    /// track-title update, so listeners can take a cheaper path for the latter.
    enum Change { case state, metadata }

    /// Called on the main thread whenever state or track title changes.
    var onChange: ((Change) -> Void)?

    /// Wired by the app to step through the saved station list; also invoked
    /// by the system's next/previous media keys.
    var onNextStation: (() -> Void)?
    var onPreviousStation: (() -> Void)?

    /// Latest spectrum band levels (0…1 each, bass → treble) and whether they
    /// came from a live tap.
    var audioBands: (bands: [Float], isLive: Bool) { levelMeter.read() }

    /// Number of spectrum bands the meter computes (matches the icon's bars).
    func setSpectrumBarCount(_ count: Int) {
        levelMeter.setBandCount(count)
    }

    var isPlaying: Bool {
        switch state {
        case .connecting, .playing: return true
        case .stopped, .failed: return false
        }
    }

    override init() {
        super.init()
        timeControlObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            DispatchQueue.main.async { self?.timeControlStatusChanged() }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            self?.reconnectAfterStall(of: item)
        }
        setUpRemoteCommands()
    }

    deinit {
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
    }

    func play(_ station: Station) {
        currentStation = station
        trackTitle = nil
        state = .connecting(station)

        let item = AVPlayerItem(url: station.url)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
        metadataOutput = output

        itemStatusObservation = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(item) }
        }

        player.replaceCurrentItem(with: item)
        player.play()
        stateDidChange()
    }

    /// "Pause" for a live stream tears the connection down; Play reconnects
    /// at the live edge instead of resuming a stale buffer.
    func pause() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        metadataOutput = nil
        trackTitle = nil
        state = .stopped
        stateDidChange()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else if let station = currentStation {
            play(station)
        }
    }

    // MARK: - Playback state

    private func timeControlStatusChanged() {
        guard let station = currentStation, player.currentItem != nil, isPlaying else { return }
        switch player.timeControlStatus {
        case .playing:
            state = .playing(station)
        case .waitingToPlayAtSpecifiedRate:
            state = .connecting(station)
        default:
            return
        }
        stateDidChange()
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player.currentItem, let station = currentStation, isPlaying else { return }
        switch item.status {
        case .readyToPlay:
            // Audio mixes are unsupported on HLS; attaching there risks side
            // effects for no data, so only tap progressive streams.
            let ext = station.url.pathExtension.lowercased()
            if ext != "m3u8" && ext != "m3u" {
                Task { await self.levelMeter.attach(to: item) }
            }
        case .failed:
            NSLog("Rdio: stream failed for %@: %@", station.name, String(describing: item.error))
            player.replaceCurrentItem(with: nil)
            state = .failed(station)
            stateDidChange()
        default:
            break
        }
    }

    private func reconnectAfterStall(of item: AVPlayerItem) {
        guard item === player.currentItem, let station = currentStation, isPlaying else { return }
        state = .connecting(station)
        stateDidChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isPlaying, self.currentStation == station,
                  self.player.timeControlStatus != .playing else { return }
            self.play(station)
        }
    }

    private func stateDidChange() {
        notifyChange(.state)
    }

    private func notifyChange(_ kind: Change) {
        updateNowPlayingInfo()
        onChange?(kind)
    }

    // MARK: - Track metadata (ICY stream titles)

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        guard output === metadataOutput else { return }  // late delivery from a previous station
        let items = groups.flatMap(\.items)
        guard let item = items.first(where: {
            $0.identifier == .icyMetadataStreamTitle || $0.commonKey == .commonKeyTitle
        }) ?? items.first else { return }

        Task { @MainActor in
            guard let title = try? await item.load(.stringValue), !title.isEmpty,
                  output === self.metadataOutput else { return }
            self.trackTitle = title
            self.notifyChange(.metadata)
        }
    }

    // MARK: - Media keys / Control Center

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        _ = center.playCommand.addTarget { [weak self] _ in
            guard let self, let station = self.currentStation else { return .commandFailed }
            DispatchQueue.main.async { if !self.isPlaying { self.play(station) } }
            return .success
        }
        _ = center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            DispatchQueue.main.async { if self.isPlaying { self.pause() } }
            return .success
        }
        _ = center.stopCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            DispatchQueue.main.async { if self.isPlaying { self.pause() } }
            return .success
        }
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.currentStation != nil else { return .commandFailed }
            DispatchQueue.main.async { self.togglePlayPause() }
            return .success
        }
        _ = center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.onNextStation != nil else { return .commandFailed }
            DispatchQueue.main.async { self.onNextStation?() }
            return .success
        }
        _ = center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.onPreviousStation != nil else { return .commandFailed }
            DispatchQueue.main.async { self.onPreviousStation?() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let station = currentStation, isPlaying else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: trackTitle ?? station.name,
            MPMediaItemPropertyArtist: station.name,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        center.playbackState = player.timeControlStatus == .playing ? .playing : .paused
    }
}
