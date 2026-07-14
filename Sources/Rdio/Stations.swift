import Foundation

struct Station: Codable, Equatable {
    let name: String
    let url: URL
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
