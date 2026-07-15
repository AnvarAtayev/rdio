import Foundation

/// Shared "GET + 200-or-throw" plumbing.
enum HTTP {
    /// Thrown for any non-200 response. Callers that care about a specific
    /// status (e.g. GitHub's 404 for "no releases") can match on `code`.
    struct StatusError: Error { let code: Int }

    /// GET the URL, returning the body on 200 and throwing otherwise.
    static func get(_ url: URL) async throws -> Data {
        try await get(URLRequest(url: url))
    }

    /// GET a pre-built request (for callers that set headers), same 200 rule.
    static func get(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw StatusError(code: http.statusCode)
        }
        return data
    }

    /// GET and JSON-decode in one step.
    static func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await get(url))
    }
}
