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

/// Checks GitHub releases for a newer version. Point `repo` at the app's
/// repository once it's published — until then checks report "no releases".
enum UpdateChecker {
    static let repo = "anvar936/rdio"
    static let autoCheckKey = "AutoUpdateCheck"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
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

        init(id: UUID = UUID(), name: String = "", urlString: String = "") {
            self.id = id
            self.name = name
            self.urlString = urlString
        }

        var url: URL? {
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }

    @Published var selectedTab: SettingsTab = .stations

    // MARK: Stations

    @Published var stations: [EditableStation] = []

    // MARK: Design

    @Published var iconStyle: IconStyle {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: IconStyle.styleKey)
            onIconSettingsChanged?()
        }
    }
    @Published var barCount: Int {
        didSet {
            UserDefaults.standard.set(barCount, forKey: IconStyle.barCountKey)
            onIconSettingsChanged?()
        }
    }
    @Published var idleIcon: String {
        didSet {
            UserDefaults.standard.set(idleIcon, forKey: IdleIcon.key)
            onIconSettingsChanged?()
        }
    }
    @Published var showNowPlayingText: Bool {
        didSet {
            UserDefaults.standard.set(showNowPlayingText, forKey: IconStyle.nowPlayingTextKey)
            onIconSettingsChanged?()
        }
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
    @Published var panelTitle = "Radio Garden"
    @Published var panelChannels: [RadioGarden.Channel] = []
    @Published var isLoading = false
    @Published var errorText: String?
    /// Bumped whenever `focusRegion` should be applied to the map camera.
    @Published var focusCounter = 0
    private(set) var focusRegion: MKCoordinateRegion?

    var playHandler: ((Station) -> Void)?
    var onIconSettingsChanged: (() -> Void)?

    private var saveTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        iconStyle = IconStyle(rawValue: defaults.string(forKey: IconStyle.styleKey) ?? "") ?? .spectrum
        barCount = max(3, min(8, defaults.integer(forKey: IconStyle.barCountKey)))
        idleIcon = defaults.string(forKey: IdleIcon.key) ?? IdleIcon.options[0].symbol
        showNowPlayingText = defaults.bool(forKey: IconStyle.nowPlayingTextKey)
        autoUpdateCheck = defaults.bool(forKey: UpdateChecker.autoCheckKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        reloadStationsFromDisk()
    }

    // MARK: - Stations

    func reloadStationsFromDisk() {
        stations = Stations.load().map {
            EditableStation(name: $0.name, urlString: $0.url.absoluteString)
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
                  !row.name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Station(name: row.name, url: url)
        }
        Stations.save(valid)
    }

    // MARK: - About

    func checkForUpdates() async {
        updateStatus = "Checking…"
        do {
            if let latest = try await UpdateChecker.latestVersion() {
                updateStatus = latest == UpdateChecker.currentVersion
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
        panelChannels = []
        defer { isLoading = false }
        do {
            panelChannels = try await RadioGarden.channels(inPlace: place.id)
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
            panelChannels = results.channels
            panelTitle = results.channels.isEmpty ? "No stations for “\(query)”" : "Results for “\(query)”"
            if let placeID = results.placeIDs.first,
               let place = allPlaces.first(where: { $0.id == placeID }) {
                focusRegion = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))
                focusCounter += 1
            }
        } catch {
            errorText = "Search failed: \(error.localizedDescription)"
        }
    }

    func play(_ channel: RadioGarden.Channel) {
        playHandler?(channel.station)
    }

    func isFavorite(_ channel: RadioGarden.Channel) -> Bool {
        let urlString = channel.streamURL.absoluteString
        return stations.contains { $0.urlString == urlString }
    }

    func addFavorite(_ channel: RadioGarden.Channel) {
        guard !isFavorite(channel) else { return }
        stations.append(EditableStation(name: channel.title,
                                        urlString: channel.streamURL.absoluteString))
        scheduleSave()
    }
}
