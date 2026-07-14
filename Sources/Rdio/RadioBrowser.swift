import Foundation

/// Minimal client for the free public Radio Browser API
/// (https://api.radio-browser.info). Used only for the curated "Popular"
/// list; station discovery and search still go through Radio Garden.
enum RadioBrowser {
    struct Station {
        let name: String
        let country: String
        let streamURL: URL
    }

    /// Top-voted stations across all countries. The round-robin DNS at
    /// api.radio-browser.info points at a healthy server; we follow redirects.
    static func topStations(limit: Int = 100) async throws -> [Station] {
        let url = URL(string: "https://all.api.radio-browser.info/json/stations/topvote/\(limit)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let raw = try JSONDecoder().decode([Raw].self, from: data)
        return raw.compactMap { item -> Station? in
            let urlString = (item.url_resolved?.isEmpty == false ? item.url_resolved : nil) ?? item.url
            guard let url = URL(string: urlString) else { return nil }
            let name = item.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : Station(name: name, country: item.country, streamURL: url)
        }
    }

    private struct Raw: Decodable {
        let name: String
        let url: String
        let url_resolved: String?
        let country: String
    }
}