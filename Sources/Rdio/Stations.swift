import Foundation

struct Station: Codable, Equatable {
    let name: String
    let url: URL
    var location: String? = nil
    /// The name the station arrived with, kept so a rename can be undone.
    /// Absent for hand-added stations and for files written before this existed.
    var defaultName: String? = nil
}

enum Stations {
    static let defaults: [Station] = [
        Station(name: "SomaFM Groove Salad", url: URL(string: "https://ice2.somafm.com/groovesalad-128-mp3")!),
        Station(name: "SomaFM Drone Zone", url: URL(string: "https://ice2.somafm.com/dronezone-128-mp3")!),
        Station(name: "SomaFM DEF CON Radio", url: URL(string: "https://ice2.somafm.com/defcon-128-mp3")!),
        Station(name: "Radio Paradise", url: URL(string: "https://stream.radioparadise.com/mp3-192")!),
        Station(name: "FIP", url: URL(string: "https://icecast.radiofrance.fr/fip-midfi.mp3")!),
        Station(name: "KEXP", url: URL(string: "https://kexp-mp3-128.streamguys1.com/kexp128.mp3")!),
    ]

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rdio/stations.json")
    }

    /// Last-modified time of the stations file, or nil if it doesn't exist.
    /// Used to skip re-reading + decoding when the file is unchanged.
    static var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// Loads the station list, seeding the file with defaults on first run.
    /// A missing or unparseable file falls back to the defaults.
    static func load() -> [Station] {
        if let data = try? Data(contentsOf: fileURL),
           let stations = try? JSONDecoder().decode([Station].self, from: data),
           !stations.isEmpty {
            return stations
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            save(defaults)
        }
        return defaults
    }

    static func save(_ stations: [Station]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(stations) {
            try? data.write(to: fileURL)
        }
    }
}

/// The handful of stations pinned to the menu bar dropdown.
///
/// Held as stream URLs rather than as a flag on `Station`: `Station` is
/// `Equatable` across every field and the app matches the playing station by
/// value, so a star that changed a station's value would drop its tick in the
/// menu and lose its place in the next/previous walk.
enum Favorites {
    /// The dropdown is a menu, not a library.
    static let limit = 5
    private static let key = "FavoriteStationURLs"

    static var urls: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func contains(_ url: URL) -> Bool {
        urls.contains(url.absoluteString)
    }

    /// Starring past the limit does nothing; the star button is disabled there.
    static func toggle(_ url: URL) {
        var current = urls
        if let index = current.firstIndex(of: url.absoluteString) {
            current.remove(at: index)
        } else if current.count < limit {
            current.append(url.absoluteString)
        }
        UserDefaults.standard.set(current, forKey: key)
    }

    /// Drops stars belonging to stations that have left My Stations — deleted in
    /// the editor or removed by hand from stations.json. Without this they hold a
    /// slot forever, with nothing on screen left to unstar.
    static func prune(keeping urlStrings: [String]) {
        let live = Set(urlStrings)
        let kept = urls.filter(live.contains)
        if kept.count != urls.count {
            UserDefaults.standard.set(kept, forKey: key)
        }
    }
}

/// The stations played most recently, newest first.
///
/// Whole stations rather than references into My Stations: something found
/// through search, the map or shuffle and never saved still belongs here.
enum Recents {
    /// Counting whatever is on air, which sits in the list with a tick rather
    /// than being held out of it. This is both what the dropdown lists and what
    /// next/previous walk — the two are the same list, so the arrows can never
    /// reach a station the menu doesn't show.
    static let limit = 3
    private static let key = "RecentStations"

    static var stations: [Station] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Station].self, from: data)
        else { return [] }
        // Trimmed on the way out as well as in, so a list saved under a larger
        // limit shrinks on sight instead of waiting for the next play.
        return Array(decoded.prefix(limit))
    }

    /// Records a deliberate pick — a menu click, a row in Settings, shuffle, a
    /// map or search result.
    ///
    /// Stepping with next/previous deliberately does *not* come through here.
    /// Bumping each station to the front as you arrived would reorder the list
    /// mid-walk, and the arrows would bounce between two stations instead of
    /// moving through it.
    static func record(_ station: Station) {
        var list = stations.filter { $0.url != station.url }
        list.insert(station, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
