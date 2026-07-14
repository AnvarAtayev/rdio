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
        let data = try await get(components.url!)
        let result = try JSONDecoder().decode(SearchResponse.self, from: data)
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

    private static var cachedPlaces: [Place] = []

    /// All ~12k Radio Garden places. Fetched once per launch and cached on
    /// disk for a week (the payload is ~1.8 MB).
    static func places() async throws -> [Place] {
        if !cachedPlaces.isEmpty { return cachedPlaces }

        let cacheURL = Stations.fileURL.deletingLastPathComponent()
            .appendingPathComponent("places-cache.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 7 * 24 * 3600,
           let data = try? Data(contentsOf: cacheURL),
           let places = try? JSONDecoder().decode([Place].self, from: data),
           !places.isEmpty {
            cachedPlaces = places
            return places
        }

        let data = try await get(URL(string: "https://radio.garden/api/ara/content/places")!)
        let decoded = try JSONDecoder().decode(PlacesResponse.self, from: data)
        let places = decoded.data.list.compactMap { raw -> Place? in
            guard raw.geo.count == 2 else { return nil }
            return Place(id: raw.id, title: raw.title, country: raw.country,
                         latitude: raw.geo[1], longitude: raw.geo[0], size: raw.size ?? 1)
        }
        cachedPlaces = places
        if let encoded = try? JSONEncoder().encode(places) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? encoded.write(to: cacheURL)
        }
        return places
    }

    /// Stations broadcasting from a given place.
    static func channels(inPlace placeID: String) async throws -> [Channel] {
        let data = try await get(URL(string: "https://radio.garden/api/ara/content/page/\(placeID)/channels")!)
        let decoded = try JSONDecoder().decode(ChannelsResponse.self, from: data)
        let placeTitle = decoded.data.title
        return decoded.data.content.flatMap(\.items).compactMap { item in
            guard let page = item.page, page.type == "channel",
                  let id = page.url.split(separator: "/").last, !id.isEmpty else { return nil }
            return Channel(title: page.title, subtitle: placeTitle, channelID: String(id))
        }
    }

    // MARK: - Plumbing

    private static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

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
