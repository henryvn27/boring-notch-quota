// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

protocol CodexLocalCostEstimating: Sendable {
    func estimate(interval: DateInterval) async throws -> CodexCostEstimate
}

enum CodexLocalCostServiceError: LocalizedError {
    case invalidInterval
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidInterval: "The requested cost interval is invalid."
        case .unavailable: "No local Codex token counters were available."
        }
    }
}

/// A bounded, read-only approximation of the local Codex token-counter scan.
/// It intentionally reports partial coverage whenever a record or model cannot be priced.
actor CodexLocalCostService: CodexLocalCostEstimating {
    private static let pricingAsOf = Date(timeIntervalSince1970: 1_784_505_600)
    private static let maximumFileBytes = 16 * 1_024 * 1_024
    private static let maximumLineBytes = 1 * 1_024 * 1_024
    private static let maximumFiles = 250
    private static let maximumScanDuration: TimeInterval = 12

    private let roots: [URL]

    init(roots: [URL]? = nil) {
        if let roots {
            self.roots = roots
        } else {
            let codex = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
            self.roots = [
                codex.appendingPathComponent("sessions", isDirectory: true),
                codex.appendingPathComponent("archived_sessions", isDirectory: true),
            ]
        }
    }

    func estimate(interval: DateInterval) async throws -> CodexCostEstimate {
        guard interval.start < interval.end else {
            throw CodexLocalCostServiceError.invalidInterval
        }

        let deadline = Date().addingTimeInterval(Self.maximumScanDuration)
        let files = discoverFiles(for: interval, deadline: deadline)
        var total = Decimal.zero
        var pricedTokens: Int64 = 0
        var unpricedTokens: Int64 = 0
        var partial = false

        for url in files {
            try Task.checkCancellation()
            if Date() >= deadline {
                partial = true
                break
            }
            let result = scan(url: url, interval: interval, deadline: deadline)
            total += result.amount
            pricedTokens += result.pricedTokens
            unpricedTokens += result.unpricedTokens
            partial = partial || result.partial
        }

        return CodexCostEstimate(
            measurement: CodexCostMeasurement(
                amount: total,
                currency: "USD",
                pricingAsOf: Self.pricingAsOf,
                interval: interval,
                partial: partial || files.isEmpty
            ),
            pricedTokenCount: pricedTokens,
            unpricedTokenCount: unpricedTokens,
            refreshedAt: Date()
        )
    }

    private func discoverFiles(for interval: DateInterval, deadline: Date) -> [URL] {
        let candidates = roots.flatMap { (root: URL) -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { item -> URL? in
                guard Date() < deadline else { return nil }
                guard let url = item as? URL, url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let fileSize = values.fileSize, fileSize <= Self.maximumFileBytes,
                      let modified = values.contentModificationDate,
                      modified >= interval.start.addingTimeInterval(-86_400) else {
                    return nil
                }
                return url
            }
        }.sorted { $0.path < $1.path }
        return Array(candidates.prefix(Self.maximumFiles))
    }

    private func scan(url: URL, interval: DateInterval, deadline: Date) -> ScanResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ScanResult(partial: true)
        }
        defer { try? handle.close() }

        var buffer = Data()
        var previous = TokenCounters.zero
        var baseline: TokenCounters?
        var latest: TokenCounters?
        var model: String?
        var sawRecord = false
        var partial = false

        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            guard line.count <= Self.maximumLineBytes else {
                partial = true
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let counters = TokenCounters(info: info) else {
                // Codex JSONL includes many non-token records. They are not an error.
                return
            }
            sawRecord = true
            if let candidate = payload["model"] as? String, !candidate.isEmpty {
                model = candidate
            }
            let timestamp = (object["timestamp"] as? String).flatMap(Self.parseDate)
            let isInInterval: Bool
            if let timestamp {
                isInInterval = interval.contains(timestamp)
            } else {
                isInInterval = true
                partial = true
            }
            if isInInterval {
                if baseline == nil { baseline = previous }
                latest = counters
            }
            previous = counters
        }

        do {
            while !Task.isCancelled, Date() < deadline,
                  let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    consume(Data(buffer[..<newline]))
                    buffer.removeSubrange(...newline)
                }
                if buffer.count > Self.maximumLineBytes {
                    buffer.removeAll(keepingCapacity: false)
                    partial = true
                }
            }
            if Task.isCancelled || Date() >= deadline { partial = true }
            if !buffer.isEmpty { consume(buffer) }
        } catch {
            partial = true
        }

        guard sawRecord, let latest else { return ScanResult(partial: partial) }
        let start = baseline ?? TokenCounters.zero
        let delta = latest.delta(from: start)
        guard !delta.isZero else { return ScanResult(partial: partial) }
        guard let model, let rates = Self.rates(for: model) else {
            return ScanResult(
                pricedTokens: 0,
                unpricedTokens: delta.billableTokens,
                partial: true
            )
        }

        return ScanResult(
            amount: Self.cost(for: delta, rates: rates),
            pricedTokens: delta.billableTokens,
            unpricedTokens: 0,
            partial: partial
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func rates(for rawModel: String) -> Rates? {
        var model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("openai/") { model.removeFirst("openai/".count) }
        if model.count > 11, model.suffix(11).first == "-" {
            model = String(model.dropLast(11))
        }
        switch model {
        case "gpt-5.6", "gpt-5.6-sol", "gpt-5-codex":
            return Rates(input: 5, cached: 0.5, cacheWrite: 6.25, output: 30)
        case "gpt-5.6-terra":
            return Rates(input: 2.5, cached: 0.25, cacheWrite: 3.125, output: 15)
        case "gpt-5.6-luna":
            return Rates(input: 1, cached: 0.1, cacheWrite: 1.25, output: 6)
        default:
            return nil
        }
    }

    private static func cost(for usage: TokenCounters, rates: Rates) -> Decimal {
        let ordinaryInput = max(0, usage.input - usage.cached - usage.cacheWrite)
        let input = Decimal(ordinaryInput) * rates.input
            + Decimal(usage.cached) * rates.cached
            + Decimal(usage.cacheWrite) * rates.cacheWrite
        let output = Decimal(usage.output) * rates.output
        return (input + output) / 1_000_000
    }

    private struct Rates {
        let input: Decimal
        let cached: Decimal
        let cacheWrite: Decimal
        let output: Decimal

        init(input: Double, cached: Double, cacheWrite: Double, output: Double) {
            self.input = Decimal(input)
            self.cached = Decimal(cached)
            self.cacheWrite = Decimal(cacheWrite)
            self.output = Decimal(output)
        }
    }

    private struct ScanResult {
        var amount: Decimal = .zero
        var pricedTokens: Int64 = 0
        var unpricedTokens: Int64 = 0
        var partial = false
    }

    private struct TokenCounters {
        let input: Int64
        let cached: Int64
        let cacheWrite: Int64
        let output: Int64

        static let zero = TokenCounters(input: 0, cached: 0, cacheWrite: 0, output: 0)

        init?(info: [String: Any]) {
            let total = (info["total_token_usage"] as? [String: Any])
                ?? (info["last_token_usage"] as? [String: Any])
            guard let total else { return nil }
            input = Self.integer(total["input_tokens"])
            cached = Self.integer(total["cached_input_tokens"])
            cacheWrite = Self.integer(total["cache_write_input_tokens"])
            output = Self.integer(total["output_tokens"])
        }

        var billableTokens: Int64 { max(0, input) + max(0, output) }
        var isZero: Bool { input == 0 && cached == 0 && cacheWrite == 0 && output == 0 }

        func delta(from previous: TokenCounters) -> TokenCounters {
            TokenCounters(
                input: max(0, input - previous.input),
                cached: max(0, cached - previous.cached),
                cacheWrite: max(0, cacheWrite - previous.cacheWrite),
                output: max(0, output - previous.output)
            )
        }

        private init(input: Int64, cached: Int64, cacheWrite: Int64, output: Int64) {
            self.input = input
            self.cached = cached
            self.cacheWrite = cacheWrite
            self.output = output
        }

        private static func integer(_ value: Any?) -> Int64 {
            if let value = value as? Int64 { return max(0, value) }
            if let value = value as? Int { return Int64(max(0, value)) }
            if let value = value as? NSNumber { return max(0, value.int64Value) }
            return 0
        }
    }
}
