import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let player = RadioPlayer()
    private var stations: [Station] = []

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var stateItem: NSMenuItem!
    private var trackItem: NSMenuItem!
    private var infoSeparator: NSMenuItem!
    private var stationItems: [NSMenuItem] = []
    private var transportView: TransportMenuView!

    private var animator: WaveformIconAnimator!
    private var staticIcon: NSImage? {
        // Pin the symbol to a point size matched to the menu bar. Without a
        // configuration SF Symbols render at intrinsic size and carry their
        // text-baseline padding, so the button centers the bounding box rather
        // than the visible glyph — which makes the icon look vertically off.
        NSImage(systemSymbolName: IdleIcon.current, accessibilityDescription: "Rdio")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    private let settingsModel = SettingsModel()
    private lazy var settingsController: SettingsWindowController = {
        settingsModel.playHandler = { [weak self] station in
            self?.player.play(station)
        }
        settingsModel.onIconSettingsChanged = { [weak self] in
            guard let self else { return }
            self.player.setSpectrumBarCount(IconStyle.barCount)
            self.refreshUI()
        }
        settingsModel.togglePlayPauseHandler = { [weak self] in
            self?.togglePlayPause()
        }
        return SettingsWindowController(model: settingsModel)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        stations = Stations.load()

        UserDefaults.standard.register(defaults: [
            IconStyle.styleKey: IconStyle.spectrum.rawValue,
            IconStyle.barCountKey: 5,
            IconStyle.nowPlayingTextKey: true,
            IdleIcon.key: IdleIcon.defaultSymbol,
            UpdateChecker.autoCheckKey: true,
        ])
        player.setSpectrumBarCount(IconStyle.barCount)
        player.onNextStation = { [weak self] in self?.playAdjacent(1) }
        player.onPreviousStation = { [weak self] in self?.playAdjacent(-1) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let staticIcon {
            statusItem.button?.image = staticIcon
        } else {
            statusItem.button?.title = "♫"
        }
        animator = WaveformIconAnimator(button: statusItem.button, player: player)
        transportView = TransportMenuView(target: self,
                                          previous: #selector(playPrevious),
                                          playPause: #selector(togglePlayPause),
                                          next: #selector(playNext))
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        player.onChange = { [weak self] in self?.refreshUI() }
        rebuildMenu()

        // Debug harness: open settings automatically so memory/CPU can be
        // measured without a human clicking the menu. Optional tab name.
        if CommandLine.arguments.contains("--open-settings") {
            let tab: SettingsTab = CommandLine.arguments.compactMap { SettingsTab(rawValue: $0) }.first ?? .stations
            settingsController.show(tab: tab)
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        stateItem = addInfoItem("")
        stateItem.isHidden = true
        trackItem = addInfoItem("")
        trackItem.isHidden = true

        infoSeparator = .separator()
        menu.addItem(infoSeparator)

        let transportItem = NSMenuItem()
        transportItem.view = transportView
        menu.addItem(transportItem)

        menu.addItem(.separator())

        stationItems = stations.map { station in
            let item = NSMenuItem(
                title: station.name, action: #selector(stationClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = station
            return item
        }
        stationItems.forEach { menu.addItem($0) }

        menu.addItem(.separator())

        let search = NSMenuItem(
            title: "Search...", action: #selector(openMapSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)

        let settings = NSMenuItem(
            title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Rdio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        refreshUI()
    }

    private func addInfoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    private func refreshUI() {
        guard stateItem != nil else { return }

        // Only surface status the transport buttons can't show themselves:
        // connecting and errors. Stopped/playing are clear from the buttons,
        // the checkmarked station, and the track line below.
        switch player.state {
        case .connecting(let station):
            stateItem.title = "Connecting to \(station.name)…"
            stateItem.isHidden = false
        case .failed(let station):
            stateItem.title = "Stream failed: \(station.name)"
            stateItem.isHidden = false
        case .stopped, .playing:
            stateItem.isHidden = true
        }

        if player.isPlaying, let track = player.trackTitle, !track.isEmpty {
            trackItem.title = track.count > 60 ? String(track.prefix(60)) + "…" : track
            trackItem.isHidden = false
        } else {
            trackItem.isHidden = true
        }

        infoSeparator.isHidden = stateItem.isHidden && trackItem.isHidden

        transportView.update(isPlaying: player.isPlaying,
                             canPlay: player.currentStation != nil || !stations.isEmpty,
                             canSkip: !stations.isEmpty)

        for item in stationItems {
            guard let station = item.representedObject as? Station else { continue }
            item.state = station == player.currentStation && player.isPlaying ? .on : .off
        }

        if case .playing(let station) = player.state {
            statusItem.button?.toolTip = [station.name, player.trackTitle].compactMap { $0 }
                .joined(separator: " — ")
        } else {
            statusItem.button?.toolTip = "Rdio"
        }

        let showText = UserDefaults.standard.bool(forKey: IconStyle.nowPlayingTextKey)
        if showText, case .playing(let station) = player.state {
            let text = player.trackTitle ?? station.name
            statusItem.button?.title = " " + (text.count > 28 ? String(text.prefix(28)) + "…" : text)
            statusItem.button?.imagePosition = .imageLeading
        } else {
            statusItem.button?.title = ""
            statusItem.button?.imagePosition = .imageOnly
        }

        updateIconAnimation()
        settingsModel.isPlaying = player.isPlaying
    }

    private func updateIconAnimation() {
        var animate = false
        if case .playing = player.state {
            animate = IconStyle.current != .off
        }
        if animate {
            animator.start()
        } else {
            animator.stop()
            statusItem.button?.image = staticIcon
        }
    }

    /// Picks up manual edits to stations.json every time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = Stations.load()
        if fresh != stations {
            stations = fresh
            rebuildMenu()
        }
    }

    // MARK: - Actions

    @objc private func stationClicked(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? Station else { return }
        player.play(station)
    }

    @objc private func togglePlayPause() {
        if player.currentStation == nil, let first = stations.first {
            player.play(first)
        } else {
            player.togglePlayPause()
        }
    }

    @objc private func playPrevious() {
        playAdjacent(-1)
    }

    @objc private func playNext() {
        playAdjacent(1)
    }

    /// Steps through the saved station list, wrapping at the ends.
    private func playAdjacent(_ offset: Int) {
        guard !stations.isEmpty else { return }
        let index: Int
        if let current = player.currentStation,
           let position = stations.firstIndex(of: current) {
            index = (position + offset + stations.count) % stations.count
        } else {
            index = offset >= 0 ? 0 : stations.count - 1
        }
        player.play(stations[index])
    }

    @objc private func openSettings() {
        settingsController.show(tab: .stations)
    }

    @objc private func openMapSearch() {
        settingsController.show(tab: .stations)
    }
}
