import Foundation

protocol CodexResetForecastFetching: Sendable {
    func fetchForecast() async throws -> CodexResetForecast
}

struct CodexResetForecastService: CodexResetForecastFetching, @unchecked Sendable {
    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = URLSession(configuration: .ephemeral),
        endpoint: URL = CodexResetForecast.endpointURL
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func fetchForecast() async throws -> CodexResetForecast {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 512 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CodexResetForecast {
        let envelope = try JSONDecoder().decode(ForecastEnvelope.self, from: data)
        return CodexResetForecast(
            score: min(max(envelope.forecast.score, 0), 100),
            resetAnnounced: envelope.forecast.resetAnnounced,
            fetchedAt: parseDate(envelope.fetchedAt),
            nextRefreshAt: parseDate(envelope.nextRefreshAt)
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct ForecastEnvelope: Decodable {
    let fetchedAt: String?
    let nextRefreshAt: String?
    let forecast: ForecastPayload
}

private struct ForecastPayload: Decodable {
    let score: Double
    let resetAnnounced: Bool
}
