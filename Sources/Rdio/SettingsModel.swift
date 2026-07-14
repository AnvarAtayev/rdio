import Foundation
import MapKit
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case stations, design, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stations: "Stations"
        case .design: "Design"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .stations: "dot.radiowaves.left.and.right"
        case .design: "paintbrush"
        case .about: "info.circle"
        }
    }
}

/// Appearance of the settings window: follow macOS, or pin it light or dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    static let key = "Appearance"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// A nil appearance hands the choice back to macOS.
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// External links surfaced by the app (About page, sidebar toolbar, etc.).
/// Edit these in one place.
enum AppLinks {
    static let coffee = URL(string: "https://buymeacoffee.com/aatayev")!
}

/// Unified shape of anything shown in the Stations search results panel:
/// either a Radio Garden channel or a Radio Browser popular station.
struct PanelStation: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let streamURL: URL

    var station: Station { Station(name: title, url: streamURL) }
}

extension RadioGarden.Channel {
    var panelStation: PanelStation {
        PanelStation(
            id: "garden:" + channelID,
            title: title, subtitle: subtitle,
            streamURL: streamURL)
    }
}

/// Checks GitHub releases for a newer version. Point `repo` at the app's
/// repository once it's published — until then checks report "no releases".
enum UpdateChecker {
    static let repo = "AnvarAtayev/rdio"
    static let autoCheckKey = "AutoUpdateCheck"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// URL for filing issues, derived from `repo`.
    static var issuesURL: URL {
        URL(string: "https://github.com/\(repo)/issues")!
    }

    /// Latest published version tag, or nil when the repo has no releases.
    static func latestVersion() async throws -> String? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Release: Decodable { let tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}

/// Shared state for the settings window: editable favorites, Radio Garden
/// map data, appearance, and app options. Station changes persist (debounced)
/// to stations.json; the menu re-reads that file every time it opens.
@MainActor
final class SettingsModel: ObservableObject {
    struct EditableStation: Identifiable, Equatable {
        let id: UUID
        var name: String
        var urlString: String
        var location: String? = nil
        var defaultName: String? = nil

        init(
            id: UUID = UUID(), name: String = "", urlString: String = "",
            location: String? = nil, defaultName: String? = nil
        ) {
            self.id = id
            self.name = name
            self.urlString = urlString
            self.location = location
            self.defaultName = defaultName
        }

        var url: URL? {
            guard let url = URL(string: urlString),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { return nil }
            return url
        }

        /// The name this station came with — recorded when it was added from the
        /// directory, or failing that the built-in list matched on stream URL, so
        /// the stations shipped with the app can be reset too. Nil once there's
        /// nothing to reset to, or when the name already matches it.
        var resettableName: String? {
            let original =
                defaultName
                ?? Stations.defaults.first { $0.url.absoluteString == urlString }?.name
            guard let original, original != name else { return nil }
            return original
        }
    }

    @Published var selectedTab: SettingsTab = .stations

    // MARK: Stations

    @Published var stations: [EditableStation] = []

    // MARK: Design

    /// False while the settings window is closed. The icon preview animates on a
    /// timer, and a closed window keeps its SwiftUI tree alive, so without this
    /// the preview would keep redrawing on the main thread for the life of the
    /// app — starving the status item that has to open the menu.
    @Published var windowIsVisible = false

    @Published var iconStyle: IconStyle {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: IconStyle.styleKey)
            DispatchQueue.main.async { self.onIconSettingsChanged?() }
        }
    }
    @Published var barCount: Int {
        didSet {
            UserDefaults.standard.set(barCount, forKey: IconStyle.barCountKey)
            DispatchQueue.main.async { self.onIconSettingsChanged?() }
        }
    }
    @Published var idleIcon: String {
        didSet {
            UserDefaults.standard.set(idleIcon, forKey: IdleIcon.key)
            DispatchQueue.main.async { self.onIconSettingsChanged?() }
        }
    }
    @Published var showNowPlayingText: Bool {
        didSet {
            UserDefaults.standard.set(showNowPlayingText, forKey: IconStyle.nowPlayingTextKey)
            DispatchQueue.main.async { self.onIconSettingsChanged?() }
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: AppAppearance.key)
            appearance.apply()
        }
    }

    // MARK: Now playing

    /// Whatever the player last loaded, playing or paused — drives the bar at the
    /// bottom of the window. Nil when nothing has been played yet.
    @Published var nowPlayingStation: Station?
    @Published var nowPlayingTrack: String?

    var isNowPlayingFavorite: Bool {
        guard let station = nowPlayingStation else { return false }
        return stations.contains { $0.urlString == station.url.absoluteString }
    }

    /// Keeps or drops the station currently on air — the only way to hold on to a
    /// station that Surprise Me picked for you, and to undo that again.
    func toggleFavoriteNowPlaying() {
        guard let station = nowPlayingStation else { return }
        if isNowPlayingFavorite {
            stations.removeAll { $0.urlString == station.url.absoluteString }
        } else {
            stations.append(
                EditableStation(
                    name: station.name,
                    urlString: station.url.absoluteString,
                    location: station.location,
                    defaultName: station.defaultName ?? station.name))
        }
        scheduleSave()
    }

    // MARK: About

    @Published var autoUpdateCheck: Bool {
        didSet { UserDefaults.standard.set(autoUpdateCheck, forKey: UpdateChecker.autoCheckKey) }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    @Published var launchAtLoginError: String?
    @Published var updateStatus = ""

    // MARK: Map

    @Published var searchText = ""
    @Published var allPlaces: [RadioGarden.Place] = []
    @Published var visiblePlaces: [RadioGarden.Place] = []
    /// Empty until the panel has something to name — a place, a search, Popular.
    @Published var panelTitle = ""
    @Published var panelStations: [PanelStation] = []
    @Published var isLoading = false
    @Published var errorText: String?
    /// Bumped whenever `focusRegion` should be applied to the map camera.
    @Published var focusCounter = 0
    private(set) var focusRegion: MKCoordinateRegion?

    var playHandler: ((Station) -> Void)?
    var onIconSettingsChanged: (() -> Void)?
    /// Toggle playback from the settings window's sidebar toolbar.
    var togglePlayPauseHandler: (() -> Void)?
    /// Skip to the next station from the now-playing bar.
    var nextStationHandler: (() -> Void)?
    /// Mirrors `RadioPlayer.isPlaying` so the sidebar's play/pause button
    /// can reflect live state. Pushed from `AppDelegate.refreshUI`.
    @Published var isPlaying = false

    private var saveTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        iconStyle =
            IconStyle(rawValue: defaults.string(forKey: IconStyle.styleKey) ?? "") ?? .spectrum
        barCount = max(3, min(8, defaults.integer(forKey: IconStyle.barCountKey)))
        idleIcon = defaults.string(forKey: IdleIcon.key) ?? IdleIcon.defaultSymbol
        showNowPlayingText = defaults.bool(forKey: IconStyle.nowPlayingTextKey)
        autoUpdateCheck = defaults.bool(forKey: UpdateChecker.autoCheckKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        appearance = AppAppearance.current
        reloadStationsFromDisk()
    }

    // MARK: - Stations

    func reloadStationsFromDisk() {
        stations = Stations.load().map {
            EditableStation(
                name: $0.name, urlString: $0.url.absoluteString,
                location: $0.location, defaultName: $0.defaultName)
        }
    }

    func addStation() {
        stations.append(EditableStation(name: "New Station", urlString: "https://"))
        scheduleSave()
    }

    func remove(_ station: EditableStation) {
        stations.removeAll { $0.id == station.id }
        scheduleSave()
    }

    func moveStations(from source: IndexSet, to destination: Int) {
        stations.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func playRow(_ station: EditableStation) {
        guard let url = station.url else { return }
        playHandler?(Station(name: station.name, url: url))
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    /// Writes the valid rows to stations.json; rows with an empty name or a
    /// non-http(s) URL stay in the editor but aren't persisted yet.
    func persistNow() {
        let valid = stations.compactMap { row -> Station? in
            guard let url = row.url,
                !row.name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return Station(
                name: row.name, url: url, location: row.location,
                defaultName: row.defaultName)
        }
        Stations.save(valid)
    }

    // MARK: - About

    func checkForUpdates() async {
        updateStatus = "Checking…"
        do {
            if let latest = try await UpdateChecker.latestVersion() {
                updateStatus =
                    latest == UpdateChecker.currentVersion
                    ? "You're up to date (\(UpdateChecker.currentVersion))."
                    : "Version \(latest) is available on GitHub."
            } else {
                updateStatus = "No releases published yet."
            }
        } catch {
            updateStatus = "Update check failed: \(error.localizedDescription)"
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }

    // MARK: - Map

    func loadPlacesIfNeeded() async {
        guard allPlaces.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            allPlaces = try await RadioGarden.places()
            if visiblePlaces.isEmpty {
                visiblePlaces = Array(allPlaces.sorted { $0.size > $1.size }.prefix(150))
            }
        } catch {
            errorText = "Couldn't load places: \(error.localizedDescription)"
        }
    }

    /// Releases the in-memory ~1.8 MB places cache when the settings window
    /// closes. The on-disk cache (`RadioGarden.placesCacheURL`) remains, so
    /// the next open re-populates the map cheaply without a network fetch.
    func releaseMapCache() {
        allPlaces = []
        visiblePlaces = []
    }

    /// Keeps the map readable: only the ~150 biggest places in view get dots.
    /// Publishes only when the set actually changes — republishing identical
    /// content rebuilds every annotation and can feed back into map updates.
    func updateVisiblePlaces(for region: MKCoordinateRegion) {
        guard !allPlaces.isEmpty else { return }
        let latHalf = region.span.latitudeDelta / 2
        let lonHalf = region.span.longitudeDelta / 2
        let center = region.center
        let candidates = allPlaces.filter { place in
            guard abs(place.latitude - center.latitude) <= latHalf else { return false }
            var lonDistance = abs(place.longitude - center.longitude)
            lonDistance = min(lonDistance, 360 - lonDistance)
            return lonDistance <= lonHalf
        }
        let next = Array(candidates.sorted { $0.size > $1.size }.prefix(150))
        if next.map(\.id) != visiblePlaces.map(\.id) {
            visiblePlaces = next
        }
    }

    func selectPlace(_ place: RadioGarden.Place) async {
        isLoading = true
        errorText = nil
        panelTitle = "\(place.title), \(place.country)"
        panelStations = []
        defer { isLoading = false }
        do {
            panelStations = try await RadioGarden.channels(inPlace: place.id).map(\.panelStation)
        } catch {
            errorText = "Couldn't load stations: \(error.localizedDescription)"
        }
    }

    func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let results = try await RadioGarden.search(query)
            panelStations = results.channels.map(\.panelStation)
            panelTitle =
                panelStations.isEmpty ? "No stations for “\(query)”" : "Results for “\(query)”"
            if let placeID = results.placeIDs.first,
                let place = allPlaces.first(where: { $0.id == placeID })
            {
                focusRegion = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: place.latitude, longitude: place.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))
                focusCounter += 1
            }
        } catch {
            errorText = "Search failed: \(error.localizedDescription)"
        }
    }

    /// Grab and play a station from a random Radio Garden place. Re-tries a few
    /// times in case the picked place turns out to have no channels.
    func surpriseMe() async {
        let places = allPlaces
        guard !places.isEmpty else {
            errorText = "Loading stations… try again in a moment."
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        for _ in 0..<4 {
            let place = places.randomElement()!
            do {
                let channels = try await RadioGarden.channels(inPlace: place.id)
                if let picked = channels.randomElement() {
                    playHandler?(picked.station)
                    return
                }
            } catch {
                errorText = "Couldn't load: \(error.localizedDescription)"
            }
        }
        errorText = "No luck — try again."
    }

    /// Curated top-voted stations via the Radio Browser API. Shown in the same
    /// results panel as search/map hits.
    func loadPopular() async {
        isLoading = true
        errorText = nil
        panelStations = []
        defer { isLoading = false }
        do {
            let top = try await RadioBrowser.topStations()
            panelStations = top.map {
                PanelStation(
                    id: "browser:" + $0.streamURL.absoluteString,
                    title: $0.name,
                    subtitle: $0.country,
                    streamURL: $0.streamURL)
            }
            panelTitle = "Popular stations"
        } catch {
            errorText = "Couldn't load popular stations: \(error.localizedDescription)"
        }
    }

    func play(_ station: PanelStation) {
        playHandler?(station.station)
    }

    func isFavorite(_ station: PanelStation) -> Bool {
        let urlString = station.streamURL.absoluteString
        return stations.contains { $0.urlString == urlString }
    }

    func addFavorite(_ station: PanelStation) {
        guard !isFavorite(station) else { return }
        stations.append(
            EditableStation(
                name: station.title,
                urlString: station.streamURL.absoluteString,
                location: station.subtitle.isEmpty ? nil : station.subtitle,
                defaultName: station.title))
        scheduleSave()
    }

    func toggleFavorite(_ station: PanelStation) {
        if isFavorite(station) {
            stations.removeAll { $0.urlString == station.streamURL.absoluteString }
        } else {
            addFavorite(station)
        }
        scheduleSave()
    }
}
