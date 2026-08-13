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
    /// Hidden alongside `infoItem` when idle, so the menu doesn't open on a
    /// stray line with nothing above it.
    private var infoSeparator: NSMenuItem!
    private var stationItems: [NSMenuItem] = []
    /// Where the Recents/Favourites blocks begin, and how many rows they occupy,
    /// so they can be swapped without disturbing the rows around them.
    private var stationSectionStart = 0
    private var stationSectionCount = 0
    /// Whether the dropdown is on screen. Shuffle can change the station list
    /// from inside the open menu, which is the one case that needs a live update.
    private var menuIsOpen = false
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

    /// Lazy because the actions need `self`. Nothing is deferred that matters:
    /// the model is built on its first use in `applicationDidFinishLaunching`,
    /// and because the actions are init arguments there is no way to get hold of
    /// a model that isn't wired to the player.
    private lazy var settingsModel = SettingsModel(
        actions: SettingsModel.Actions(
            play: { [weak self] station in
                self?.play(station)
            },
            togglePlayPause: { [weak self] in
                self?.togglePlayPause()
            },
            nextStation: { [weak self] in
                self?.playAdjacent(1)
            },
            iconSettingsChanged: { [weak self] in
                guard let self else { return }
                let barCount = IconStyle.barCount
                self.player.setSpectrumBarCount(barCount)
                self.animator.updateSettings()
                self.refreshUI()
            }))
    private let updater = AppUpdater()
    private lazy var settingsController = SettingsWindowController(model: settingsModel)

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
        infoSeparator = .separator()
        menu.addItem(infoSeparator)

        let transportItem = NSMenuItem()
        transportItem.view = transportView
        menu.addItem(transportItem)

        menu.addItem(.separator())

        // Everything above is fixed, so the station rows always start here and
        // can be swapped out on their own later.
        stationSectionStart = menu.numberOfItems
        stationSectionCount = 0
        refreshStationSections()

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

    /// Replaces the Recents and Favourites blocks in place, leaving every other
    /// row untouched.
    ///
    /// In place rather than by rebuilding the whole menu, because this also runs
    /// while the dropdown is on screen: the transport row is a custom view, so
    /// pressing shuffle doesn't dismiss the menu, and the recents list it changes
    /// is sitting right there. Rebuilding wholesale would tear down and replace
    /// the very row the pointer is resting on. Both blocks live below transport,
    /// so a change in their height pushes rows down rather than out from under
    /// the cursor.
    ///
    /// Either block is dropped along with its heading and separator when empty,
    /// so a fresh install shows transport and nothing else rather than a
    /// labelled gap. `sectionHeader(title:)` is AppKit's own heading style rather
    /// than a disabled row dressed up as one.
    private func refreshStationSections() {
        for _ in 0..<stationSectionCount {
            menu.removeItem(at: stationSectionStart)
        }

        stationItems = []
        var index = stationSectionStart
        let sections = [
            ("Recents", Recents.stations),
            ("Favourites", stations.filter { Favorites.contains($0.url) }),
        ]
        for (title, section) in sections where !section.isEmpty {
            menu.insertItem(.sectionHeader(title: title), at: index)
            index += 1
            for station in section {
                let item = NSMenuItem(
                    title: fitted(station.name), action: #selector(stationClicked(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = station
                item.image = MenuMetrics.iconGutter
                menu.insertItem(item, at: index)
                index += 1
                stationItems.append(item)
            }
            menu.insertItem(.separator(), at: index)
            index += 1
        }
        stationSectionCount = index - stationSectionStart
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
                             canSkip: skipList.count > 1)

        for item in stationItems {
            guard let station = item.representedObject as? Station else { continue }
            // Matched on URL, not on the whole station: a recent keeps the name
            // it had when it played, so a rename in My Stations would otherwise
            // stop the two comparing equal and drop the tick.
            let isOnAir = station.url == player.currentStation?.url && player.isPlaying
            item.image = isOnAir ? MenuMetrics.icon("checkmark") : MenuMetrics.iconGutter
        }

        updateIconAnimation()
    }

    /// The info line, tooltip and (optional) menu-bar caption — everything that
    /// tracks the current title. Shared by the full and metadata-only refreshes.
    private func updateNowPlayingText() {
        // What's on air, or why it isn't. Idle needs no line to announce itself —
        // the transport row already shows a play button rather than a pause one —
        // so the row and its separator are hidden rather than left saying
        // "Not playing". A stream that *failed* still gets its say.
        switch player.state {
        case .connecting(let station):
            infoItem.title = fitted("Connecting to \(station.name)…")
        case .failed(let station):
            infoItem.title = fitted("Stream failed: \(station.name)")
        case .playing(let station):
            let track = player.trackTitle
            infoItem.title = fitted(track?.isEmpty == false ? track! : station.name)
        case .stopped:
            infoItem.title = ""
        }
        // Hidden, not omitted: `infoItem` stays valid for the next state change,
        // and `refreshUI` keeps using it to tell a built menu from an unbuilt one.
        let idle = player.state == .stopped
        infoItem.isHidden = idle
        infoSeparator.isHidden = idle

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

    /// Rebuilds the dropdown each time it opens: recents and stars move without
    /// stations.json changing. Re-reading the file is still gated on its mtime,
    /// so an unchanged file costs a stat instead of a read + decode.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let date = Stations.modificationDate
        if date != stationsFileDate {
            stationsFileDate = date
            stations = Stations.load()
        }
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    // MARK: - Actions

    /// Every deliberate pick goes through here so it lands in the recents list.
    /// `playAdjacent` is the one exception — see `Recents.record`.
    private func play(_ station: Station) {
        Recents.record(station)
        // Shuffle plays from inside the open dropdown, so the list it just
        // changed is still on screen and has to be redrawn now. Every other
        // route dismisses the menu first and is picked up on the next open.
        // Done before playing so the tick that `player.play` triggers lands on
        // the new rows rather than the ones just discarded.
        if menuIsOpen { refreshStationSections() }
        player.play(station)
    }

    @objc private func stationClicked(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? Station else { return }
        play(station)
    }

    @objc private func togglePlayPause() {
        if player.currentStation == nil, let first = stations.first {
            play(first)
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

    /// What next/previous walk: the recently played list once there is somewhere
    /// to go, otherwise My Stations, so the arrows aren't dead on a fresh install
    /// with nothing played yet.
    private var skipList: [Station] {
        let recents = Recents.stations
        return recents.count > 1 ? recents : stations
    }

    /// Steps through `skipList`, wrapping at the ends. Plays *without* recording:
    /// bumping each station to the front of recents as you arrived would reorder
    /// the list mid-walk, bouncing between two of them instead of moving through.
    private func playAdjacent(_ offset: Int) {
        let list = skipList
        guard !list.isEmpty else { return }
        let index: Int
        if let current = player.currentStation,
           let position = list.firstIndex(where: { $0.url == current.url }) {
            index = (position + offset + list.count) % list.count
        } else {
            index = offset >= 0 ? 0 : list.count - 1
        }
        player.play(list[index])
    }

    @objc private func openSettings() {
        settingsController.show(tab: .stations)
    }
}
