import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let player = RadioPlayer()
    private var stations: [Station] = []
    /// mtime of stations.json as of the last load; lets menuNeedsUpdate skip
    /// the disk read + decode when the file hasn't changed.
    private var stationsFileDate: Date?

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var infoItem: NSMenuItem!
    private var stationItems: [NSMenuItem] = []
    private var transportView: TransportMenuView!

    private var animator: WaveformIconAnimator!
    private var staticIcon: NSImage? {
        // A status button lays out an SF Symbol image by the symbol's text
        // metrics rather than centering it, so symbols carrying a tall box —
        // "radio" worst of them — sit visibly high in the menu bar. Drawing the
        // symbol into a plain template image drops those metrics, and the button
        // then centers it like it already centers the animated waveform.
        guard let symbol = NSImage(systemSymbolName: IdleIcon.current, accessibilityDescription: "Rdio")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return nil }
        let icon = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        icon.isTemplate = true
        return icon
    }

    private let settingsModel = SettingsModel()
    private let updater = AppUpdater()
    private lazy var settingsController: SettingsWindowController = {
        settingsModel.playHandler = { [weak self] station in
            self?.player.play(station)
        }
        settingsModel.onIconSettingsChanged = { [weak self] in
            guard let self else { return }
            let barCount = IconStyle.barCount
            self.player.setSpectrumBarCount(barCount)
            self.animator.updateSettings()
            self.refreshUI()
        }
        settingsModel.togglePlayPauseHandler = { [weak self] in
            self?.togglePlayPause()
        }
        settingsModel.nextStationHandler = { [weak self] in
            self?.playAdjacent(1)
        }
        return SettingsWindowController(model: settingsModel)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        stations = Stations.load()
        stationsFileDate = Stations.modificationDate
        installEditMenu()

        UserDefaults.standard.register(defaults: [
            IconStyle.styleKey: IconStyle.spectrum.rawValue,
            IconStyle.barCountKey: 5,
            IconStyle.nowPlayingTextKey: true,
            IdleIcon.key: IdleIcon.defaultSymbol,
            UpdateChecker.autoCheckKey: true,
            AppAppearance.key: AppAppearance.system.rawValue,
        ])
        AppAppearance.current.apply()
        settingsModel.updater = updater
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
                                          next: #selector(playNext),
                                          shuffle: #selector(surpriseMe))
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        player.onChange = { [weak self] kind in self?.refreshUI(kind) }
        rebuildMenu()

        // Debug harness: open settings automatically so memory/CPU can be
        // measured without a human clicking the menu. Optional tab name.
        if CommandLine.arguments.contains("--open-settings") {
            let tab: SettingsTab = CommandLine.arguments.compactMap { SettingsTab(rawValue: $0) }.first ?? .stations
            settingsController.show(tab: tab)
        }
    }

    /// An accessory app starts with no main menu, and the standard text-editing
    /// key equivalents live on the menu rather than in the fields themselves — so
    /// without this, ⌘Z/⌘X/⌘C/⌘V/⌘A do nothing while renaming a station. The menu
    /// bar itself stays hidden; only the shortcuts come along.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        // Give the row back its narrow canvas: a previous display stretched it to
        // the menu's width, and a view that wide would floor the menu there —
        // widening it a little more on every rebuild.
        transportView.setFrameSize(NSSize(width: MenuMetrics.transportWidth,
                                          height: transportView.frame.height))
        menu.minimumWidth = MenuMetrics.width

        infoItem = addInfoItem("")
        menu.addItem(.separator())

        let transportItem = NSMenuItem()
        transportItem.view = transportView
        menu.addItem(transportItem)

        menu.addItem(.separator())

        stationItems = stations.map { station in
            let item = NSMenuItem(
                title: fitted(station.name), action: #selector(stationClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = station
            item.image = MenuMetrics.iconGutter
            return item
        }
        stationItems.forEach { menu.addItem($0) }

        menu.addItem(.separator())

        let search = NSMenuItem(
            title: "Search...", action: #selector(openSettings), keyEquivalent: "")
        search.target = self
        search.image = MenuMetrics.icon("magnifyingglass")
        menu.addItem(search)

        // Settings and Quit are left to macOS, which recognises their actions and
        // draws its own icon. Adding one here only gets it drawn beside that.
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
        item.image = MenuMetrics.iconGutter
        menu.addItem(item)
        return item
    }

    /// Clip `text` to the menu's text column, ellipsis and all. Measured in
    /// points, not characters: the menu font is proportional, so a character
    /// budget either wraps short of the edge or overruns it and widens the menu.
    private func fitted(_ text: String) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        func width(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: attributes).width
        }
        guard width(text) > MenuMetrics.textWidth else { return text }

        var clipped = text
        while !clipped.isEmpty, width(clipped + "…") > MenuMetrics.textWidth {
            clipped.removeLast()
        }
        return clipped + "…"
    }

    private func refreshUI(_ kind: RadioPlayer.Change = .state) {
        guard infoItem != nil else { return }

        // Always cheap: the info line, tooltip and menu-bar text follow the
        // track title, which changes far more often than playback state.
        updateNowPlayingText()
        settingsModel.updateNowPlaying(isPlaying: player.isPlaying,
                                       station: player.currentStation,
                                       track: player.trackTitle)

        // A track-title update leaves transport, the checkmarks and the icon
        // animation untouched, so skip that whole pass on metadata ticks.
        guard kind == .state else { return }

        transportView.update(isPlaying: player.isPlaying,
                             canPlay: player.currentStation != nil || !stations.isEmpty,
                             canSkip: !stations.isEmpty)

        for item in stationItems {
            guard let station = item.representedObject as? Station else { continue }
            let isOnAir = station == player.currentStation && player.isPlaying
            item.image = isOnAir ? MenuMetrics.icon("checkmark") : MenuMetrics.iconGutter
        }

        updateIconAnimation()
    }

    /// The info line, tooltip and (optional) menu-bar caption — everything that
    /// tracks the current title. Shared by the full and metadata-only refreshes.
    private func updateNowPlayingText() {
        // One line, always present, so the menu never changes height: what's on
        // air, or why it isn't. Never hidden — hiding it would drop a row and
        // resize the menu out from under the pointer.
        switch player.state {
        case .connecting(let station):
            infoItem.title = fitted("Connecting to \(station.name)…")
        case .failed(let station):
            infoItem.title = fitted("Stream failed: \(station.name)")
        case .playing(let station):
            let track = player.trackTitle
            infoItem.title = fitted(track?.isEmpty == false ? track! : station.name)
        case .stopped:
            infoItem.title = "Not playing"
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

    /// Picks up manual edits to stations.json when the menu opens. Gated on the
    /// file's mtime so an unchanged file costs a stat instead of a read + decode.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let date = Stations.modificationDate
        if let date, date == stationsFileDate { return }
        stationsFileDate = date
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

    @objc private func surpriseMe() {
        Task {
            await settingsModel.loadPlacesIfNeeded()
            await settingsModel.surpriseMe()
        }
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
}
