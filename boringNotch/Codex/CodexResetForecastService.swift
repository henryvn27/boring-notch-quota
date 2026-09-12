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
        // The live radar includes a bounded public event log alongside the
        // probabilities; keep a ceiling while allowing the current payload.
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CodexResetForecast {
        let decoder = JSONDecoder()

        if let radar = try? decoder.decode(RadarEnvelope.self, from: data),
           radar.code == 0,
           let data = radar.data,
           let score = data.probability48h ?? data.probability24h
        {
            let horizonHours = data.probability48h == nil ? 24 : 48
            let verdictCode = data.verdict?.lowercased()
            return CodexResetForecast(
                score: min(max(score, 0), 100),
                resetAnnounced: verdictCode == "confirmed",
                verdictCode: verdictCode,
                verdictLabel: displayLabel(for: verdictCode),
                horizonHours: horizonHours,
                sourceStale: false,
                fetchedAt: parseDate(data.updatedAt),
                nextRefreshAt: nil
            )
        }

        if let live = try? decoder.decode(LiveVerdictEnvelope.self, from: data),
           let verdict = live.verdict,
           let probabilities = live.probabilities,
           let score = probabilities.h48 ?? probabilities.h24
        {
            let horizonHours = probabilities.h48 == nil ? 24 : 48
            let fetchedAt = parseDate(live.checkedAt)
                ?? parseDate(live.freshness?.upstreamUpdatedAt)
            return CodexResetForecast(
                score: min(max(score, 0), 100),
                resetAnnounced: verdict.code == "confirmed",
                verdictCode: verdict.code,
                verdictLabel: verdict.label,
                horizonHours: horizonHours,
                sourceStale: live.freshness?.statusStale ?? false,
                fetchedAt: fetchedAt,
                nextRefreshAt: nil
            )
        }

        // Keep the parser tolerant of the retired .com payload while cached
        // or mirrored responses age out. The live source above remains the
        // only default endpoint used by the app.
        let legacy = try decoder.decode(LegacyForecastEnvelope.self, from: data)
        return CodexResetForecast(
            score: min(max(legacy.forecast.score, 0), 100),
            resetAnnounced: legacy.forecast.resetAnnounced,
            verdictCode: legacy.forecast.resetAnnounced ? "confirmed" : nil,
            verdictLabel: legacy.forecast.resetAnnounced ? "RESET CONFIRMED" : nil,
            horizonHours: legacy.forecast.horizonHours ?? 48,
            sourceStale: false,
            fetchedAt: parseDate(legacy.fetchedAt),
            nextRefreshAt: parseDate(legacy.nextRefreshAt)
        )
    }

    private static func displayLabel(for verdict: String?) -> String? {
        guard let verdict else { return nil }
        switch verdict {
        case "confirmed":
            return "RESET CONFIRMED"
        case "elevated":
            return "ELEVATED WATCH"
        case "watch":
            return "WATCH, NOT A PROMISE"
        case "low":
            return "LOW SIGNAL"
        default:
            return verdict.replacingOccurrences(of: "_", with: " ").uppercased()
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct RadarEnvelope: Decodable {
    let code: Int
    let data: RadarDataPayload?
}

private struct RadarDataPayload: Decodable {
    let probability24h: Double?
    let probability48h: Double?
    let updatedAt: String?
    let verdict: String?
}

private struct LiveVerdictEnvelope: Decodable {
    let checkedAt: String?
    let verdict: LiveVerdictPayload?
    let probabilities: LiveProbabilitiesPayload?
    let freshness: LiveFreshnessPayload?

    enum CodingKeys: String, CodingKey {
        case checkedAt = "checked_at"
        case verdict
        case probabilities
        case freshness
    }
}

private struct LiveVerdictPayload: Decodable {
    let code: String
    let label: String?
}

private struct LiveProbabilitiesPayload: Decodable {
    let h24: Double?
    let h48: Double?
}

private struct LiveFreshnessPayload: Decodable {
    let upstreamUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case upstreamUpdatedAt = "upstream_updated_at"
        case statusStale = "status_stale"
    }

    let statusStale: Bool?
}

private struct LegacyForecastEnvelope: Decodable {
    let fetchedAt: String?
    let nextRefreshAt: String?
    let forecast: LegacyForecastPayload
}

private struct LegacyForecastPayload: Decodable {
    let score: Double
    let resetAnnounced: Bool
    let horizonHours: Int?
}
