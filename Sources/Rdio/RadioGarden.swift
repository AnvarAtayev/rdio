import Foundation

/// Minimal client for Radio Garden's (unofficial) API.
enum RadioGarden {
    struct Channel {
        let title: String
        let subtitle: String
        let channelID: String

        /// Endpoint that 302-redirects to the station's actual stream;
        /// AVPlayer follows it transparently.
        var streamURL: URL {
            URL(string: "https://radio.garden/api/ara/content/listen/\(channelID)/channel.mp3")!
        }

        var station: Station { Station(name: title, url: streamURL) }
    }

    struct Place: Identifiable, Codable {
        let id: String
        let title: String
        let country: String
        let latitude: Double
        let longitude: Double
        /// Relative importance (1…~700); used to declutter the map.
        let size: Int
    }

    struct SearchResults {
        var channels: [Channel] = []
        var placeIDs: [String] = []
    }

    // MARK: - Search

    static func search(_ query: String) async throws -> SearchResults {
        var components = URLComponents(string: "https://radio.garden/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let result = try await HTTP.decode(SearchResponse.self, from: components.url!)
        var results = SearchResults()
        for hit in result.hits.hits {
            guard let page = hit._source.page else { continue }
            if page.type == "channel", let id = page.url.split(separator: "/").last, !id.isEmpty {
                results.channels.append(Channel(title: page.title,
                                                subtitle: page.subtitle ?? "",
                                                channelID: String(id)))
            } else if page.type == "page", let placeID = page.map {
                results.placeIDs.append(placeID)
            }
        }
        return results
    }

    // MARK: - Places (map dots)

    /// The on-disk places cache, kept next to `stations.json`. The decoded
    /// payload is held in memory by `SettingsModel` (so it can be released
    /// when the settings window closes) rather than as a process-lifetime
    /// static here.
    static let placesCacheURL = Stations.fileURL.deletingLastPathComponent()
        .appendingPathComponent("places-cache.json")

    /// All ~12k Radio Garden places. Reads the on-disk cache if it is less
    /// than a week old, otherwise fetches and caches the payload (~1.8 MB).
    static func places() async throws -> [Place] {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: placesCacheURL.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 7 * 24 * 3600,
           let data = try? Data(contentsOf: placesCacheURL),
           let places = try? JSONDecoder().decode([Place].self, from: data),
           !places.isEmpty {
            return places
        }

        let decoded = try await HTTP.decode(PlacesResponse.self,
                                            from: URL(string: "https://radio.garden/api/ara/content/places")!)
        let places = decoded.data.list.compactMap { raw -> Place? in
            guard raw.geo.count == 2 else { return nil }
            return Place(id: raw.id, title: raw.title, country: raw.country,
                         latitude: raw.geo[1], longitude: raw.geo[0], size: raw.size ?? 1)
        }
        if let encoded = try? JSONEncoder().encode(places) {
            try? FileManager.default.createDirectory(at: placesCacheURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? encoded.write(to: placesCacheURL)
        }
        return places
    }

    /// Stations broadcasting from a given place.
    static func channels(inPlace placeID: String) async throws -> [Channel] {
        let decoded = try await HTTP.decode(ChannelsResponse.self,
                                            from: URL(string: "https://radio.garden/api/ara/content/page/\(placeID)/channels")!)
        let placeTitle = decoded.data.title
        return decoded.data.content.flatMap(\.items).compactMap { item in
            guard let page = item.page, page.type == "channel",
                  let id = page.url.split(separator: "/").last, !id.isEmpty else { return nil }
            return Channel(title: page.title, subtitle: placeTitle, channelID: String(id))
        }
    }

    // MARK: - Plumbing

    private struct SearchResponse: Decodable {
        let hits: Hits
        struct Hits: Decodable { let hits: [Hit] }
        struct Hit: Decodable { let _source: Source }
        struct Source: Decodable { let page: Page? }
        struct Page: Decodable {
            let url: String
            let type: String
            let title: String
            let subtitle: String?
            let map: String?
        }
    }

    private struct PlacesResponse: Decodable {
        let data: DataField
        struct DataField: Decodable { let list: [RawPlace] }
        struct RawPlace: Decodable {
            let id: String
            let title: String
            let country: String
            let geo: [Double]
            let size: Int?
        }
    }

    private struct ChannelsResponse: Decodable {
        let data: DataField
        struct DataField: Decodable {
            let title: String
            let content: [Content]
        }
        struct Content: Decodable { let items: [Item] }
        struct Item: Decodable { let page: Page? }
        struct Page: Decodable {
            let url: String
            let type: String
            let title: String
        }
    }
}
