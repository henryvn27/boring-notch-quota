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
    private static let maximumFileBytes = 1_024 * 1_024 * 1_024
    private static let maximumLineBytes = 1 * 1_024 * 1_024
    // The local Codex history is intentionally bounded, but the old 250-file
    // ceiling silently dropped a large part of an active user's month. Keep a
    // generous ceiling and let the deadline be the final safety valve.
    private static let maximumFiles = 1_000
    private static let maximumScanDuration: TimeInterval = 45
    // Narrow byte markers keep large prompt/tool records out of
    // JSONSerialization while still accepting compact JSON and pretty output.
    private static let relevantMarkers: [Data] = [
        Data(#""token_count""#.utf8),
        Data(#""turn_context""#.utf8),
        Data(#""thread_settings_applied""#.utf8),
    ]

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

        // CodexBar is the reference implementation for local Codex history. Its scanner handles
        // forked/subagent rollouts, model changes, and progressive catch-up; use it when present so
        // the API-equivalent card agrees with the user's installed CodexBar. The self-contained
        // scanner below remains the fallback for machines without CodexBar.
        do {
            return try await Self.estimateWithCodexBar(interval: interval)
        } catch {
            NSLog("CodexBar local cost unavailable; using Notch fallback: %@", error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(Self.maximumScanDuration)
        let files = discoverFiles(for: interval, deadline: deadline)
        var total = Decimal.zero
        var pricedTokens: Int64 = 0
        var unpricedTokens: Int64 = 0
        var partial = false
        var dailyTotals: [Date: CostAggregate] = [:]
        var modelTotals: [String: CostAggregate] = [:]

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
            for contribution in result.contributions {
                let day = Calendar.current.startOfDay(for: contribution.date)
                dailyTotals[day, default: CostAggregate()].add(contribution)
                modelTotals[contribution.model, default: CostAggregate()].add(contribution)
            }
        }

        let dailyBreakdown = dailyTotals.map { date, aggregate in
            CodexCostDay(
                date: date,
                amount: aggregate.amount,
                pricedTokenCount: aggregate.pricedTokenCount,
                unpricedTokenCount: aggregate.unpricedTokenCount
            )
        }.sorted { $0.date > $1.date }
        let modelBreakdown = modelTotals.map { model, aggregate in
            CodexCostModel(
                model: model,
                amount: aggregate.amount,
                pricedTokenCount: aggregate.pricedTokenCount,
                unpricedTokenCount: aggregate.unpricedTokenCount
            )
        }.sorted {
            if $0.amount == $1.amount {
                return $0.model.localizedStandardCompare($1.model) == .orderedAscending
            }
            return $0.amount > $1.amount
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
            dailyBreakdown: dailyBreakdown,
            modelBreakdown: modelBreakdown,
            refreshedAt: Date()
        )
    }

    private static func estimateWithCodexBar(interval: DateInterval) async throws -> CodexCostEstimate {
        guard let executable = codexBarExecutableURL() else {
            throw CodexLocalCostServiceError.unavailable
        }

        let dayCount = max(1, Int(ceil(interval.duration / 86_400)))
        let output = try await runBoundedProcessOperation {
            let runner = try BoundedProcessRunner(
                executableURL: executable,
                arguments: [
                    "cost",
                    "--provider", "codex",
                    "--format", "json",
                    "--pretty",
                    "--days", String(dayCount),
                    "--refresh",
                ],
                timeout: 60,
                maximumOutputSize: 16 * 1_024 * 1_024
            )
            defer { runner.stop() }
            try runner.readToExit()
            return runner.output
        }

        let reports = try JSONDecoder().decode([CodexBarReport].self, from: output)
        guard let report = reports.first(where: { $0.provider == "codex" }) ?? reports.first else {
            throw CodexLocalCostServiceError.unavailable
        }

        let totalCost = Decimal(report.last30DaysCostUSD ?? report.totals?.totalCost ?? 0)
        let totalTokens = max(
            0,
            report.last30DaysTokens
                ?? report.totals?.totalTokens
                ?? report.daily.reduce(0) { $0 + ($1.totalTokens ?? 0) }
        )

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: interval.start)
        let endDay = calendar.startOfDay(for: interval.end)
        let days = report.daily.compactMap { day -> CodexCostDay? in
            guard let date = Self.codexBarDate(day.date),
                  date >= startDay,
                  date <= endDay
            else { return nil }
            let tokens = max(0, day.totalTokens ?? (day.inputTokens ?? 0) + (day.outputTokens ?? 0))
            return CodexCostDay(
                date: date,
                amount: Decimal(day.totalCost ?? 0),
                pricedTokenCount: tokens,
                unpricedTokenCount: 0
            )
        }.sorted { $0.date > $1.date }

        var modelsByName: [String: CodexBarModelAggregate] = [:]
        for day in report.daily {
            guard let date = Self.codexBarDate(day.date), date >= startDay, date <= endDay else { continue }
            for model in day.modelBreakdowns ?? [] {
                var aggregate = modelsByName[model.modelName] ?? CodexBarModelAggregate()
                aggregate.amount += Decimal(model.cost ?? 0)
                aggregate.pricedTokenCount += max(0, model.totalTokens ?? 0)
                modelsByName[model.modelName] = aggregate
            }
        }
        let models = modelsByName.map { name, aggregate in
            CodexCostModel(
                model: name,
                amount: aggregate.amount,
                pricedTokenCount: aggregate.pricedTokenCount,
                unpricedTokenCount: 0
            )
        }.sorted {
            if $0.amount == $1.amount {
                return $0.model.localizedStandardCompare($1.model) == .orderedAscending
            }
            return $0.amount > $1.amount
        }

        let coverage = report.coverage
        let partial = report.historyCoverageIsEstablished == false
            || (coverage?.estimated ?? 0) > 0
            || (coverage?.unmetered ?? 0) > 0
            || (coverage?.unpriced ?? 0) > 0
        let refreshedAt = Self.codexBarDateTime(report.updatedAt) ?? Date()
        return CodexCostEstimate(
            measurement: CodexCostMeasurement(
                amount: totalCost,
                currency: report.currencyCode ?? "USD",
                pricingAsOf: Self.pricingAsOf,
                interval: interval,
                partial: partial
            ),
            pricedTokenCount: totalTokens,
            unpricedTokenCount: 0,
            dailyBreakdown: days,
            modelBreakdown: models,
            refreshedAt: refreshedAt
        )
    }

    private static func codexBarExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/codexbar",
            "/usr/local/bin/codexbar",
            "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func codexBarDate(_ value: String) -> Date? {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var calendar = Calendar.current
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: components[0],
            month: components[1],
            day: components[2]
        ))
    }

    private static func codexBarDateTime(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private struct CodexBarReport: Decodable {
        let provider: String?
        let currencyCode: String?
        let updatedAt: String?
        let historyCoverageIsEstablished: Bool?
        let last30DaysTokens: Int64?
        let last30DaysCostUSD: Double?
        let coverage: CodexBarCoverage?
        let totals: CodexBarTotals?
        let daily: [CodexBarDay]
    }

    private struct CodexBarCoverage: Decodable {
        let estimated: Int
        let unmetered: Int
        let unpriced: Int
    }

    private struct CodexBarTotals: Decodable {
        let totalTokens: Int64?
        let totalCost: Double?
    }

    private struct CodexBarDay: Decodable {
        let date: String
        let inputTokens: Int64?
        let outputTokens: Int64?
        let totalTokens: Int64?
        let totalCost: Double?
        let modelBreakdowns: [CodexBarModel]?
    }

    private struct CodexBarModel: Decodable {
        let modelName: String
        let cost: Double?
        let totalTokens: Int64?
    }

    private struct CodexBarModelAggregate {
        var amount: Decimal = .zero
        var pricedTokenCount: Int64 = 0
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
        // Read the newest rollouts first if the bounded deadline is reached.
        // That keeps the visible estimate useful while still marking it partial.
        }.sorted { $0.path > $1.path }
        return Array(candidates.prefix(Self.maximumFiles))
    }

    private func scan(url: URL, interval: DateInterval, deadline: Date) -> ScanResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ScanResult(partial: true)
        }
        defer { try? handle.close() }

        let fallbackDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? interval.start
        var buffer = Data()
        var previous = TokenCounters.zero
        var intervalPrevious: TokenCounters?
        var contributions: [(date: Date, model: String?, usage: TokenCounters)] = []
        var model: String?
        var sawRecord = false
        var partial = false
        let primaryDateFormatter = ISO8601DateFormatter()
        primaryDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackDateFormatter = ISO8601DateFormatter()

        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            guard line.count <= Self.maximumLineBytes else {
                partial = true
                return
            }
            // Most Codex records contain large prompts/tool payloads that are
            // irrelevant to pricing. Avoid JSON-deserializing those lines;
            // only token counters and the small model-context records can
            // affect the estimate.
            guard Self.relevantMarkers.contains(where: { line.range(of: $0) != nil }) else {
                return
            }
            guard let parsed = Self.parseRelevantLine(
                line,
                primaryDateFormatter: primaryDateFormatter,
                fallbackDateFormatter: fallbackDateFormatter
            ) else {
                return
            }
            if let candidate = parsed.model, !candidate.isEmpty {
                model = candidate
            }
            guard let counters = parsed.counters else {
                return
            }
            sawRecord = true
            let timestamp = parsed.timestamp
            let isInInterval: Bool
            if let timestamp {
                isInInterval = interval.contains(timestamp)
            } else {
                isInInterval = true
                partial = true
            }
            if isInInterval {
                if intervalPrevious == nil { intervalPrevious = previous }
                if let intervalPrevious {
                    if let delta = counters.delta(from: intervalPrevious), !delta.isZero {
                        contributions.append(
                            (date: timestamp ?? fallbackDate, model: model, usage: delta)
                        )
                    } else if counters != intervalPrevious {
                        // A counter reset or interleaved rollout is not safely
                        // attributable; resume from the new high-water mark.
                        partial = true
                    }
                }
                intervalPrevious = counters
            }
            previous = counters
        }

        do {
            while !Task.isCancelled, Date() < deadline,
                  let chunk = try handle.read(upToCount: 1 * 1_024 * 1_024), !chunk.isEmpty {
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

        guard sawRecord else { return ScanResult(partial: partial) }

        var result = ScanResult(partial: partial)
        for contribution in contributions {
            let model = contribution.model ?? "Unknown model"
            let billableTokens = contribution.usage.billableTokens
            guard let rawModel = contribution.model,
                  let rates = Self.rates(for: rawModel) else {
                result.unpricedTokens += billableTokens
                result.partial = true
                result.contributions.append(
                    CostContribution(
                        date: contribution.date,
                        model: model,
                        amount: .zero,
                        pricedTokenCount: 0,
                        unpricedTokenCount: billableTokens
                    )
                )
                continue
            }
            let amount = Self.cost(for: contribution.usage, rates: rates)
            result.amount += amount
            result.pricedTokens += billableTokens
            result.contributions.append(
                CostContribution(
                    date: contribution.date,
                    model: model,
                    amount: amount,
                    pricedTokenCount: billableTokens,
                    unpricedTokenCount: 0
                )
            )
        }
        return result
    }

    private struct ParsedLine {
        let model: String?
        let counters: TokenCounters?
        let timestamp: Date?
    }

    /// Parse only the small fields that affect pricing. Codex rollout lines can
    /// contain very large prompts and tool payloads, so deserializing every
    /// token row with JSONSerialization makes a month of local history take
    /// minutes. This deliberately follows the same byte-oriented strategy as
    /// CodexBar while keeping the scanner self-contained and read-only.
    private static func parseRelevantLine(
        _ line: Data,
        primaryDateFormatter: ISO8601DateFormatter,
        fallbackDateFormatter: ISO8601DateFormatter
    ) -> ParsedLine? {
        let bytes = Array(line)
        if contains(Array(#""thread_settings_applied""#.utf8), in: bytes)
            || contains(Array(#""turn_context""#.utf8), in: bytes)
        {
            return ParsedLine(
                model: stringValue(for: "model", in: bytes),
                counters: nil,
                timestamp: nil
            )
        }

        guard contains(Array(#""token_count""#.utf8), in: bytes) else {
            return nil
        }

        let timestamp = stringValue(for: "timestamp", in: bytes).flatMap {
            primaryDateFormatter.date(from: $0) ?? fallbackDateFormatter.date(from: $0)
        }
        guard contains(Array(#""total_token_usage""#.utf8), in: bytes)
                || contains(Array(#""last_token_usage""#.utf8), in: bytes) else {
            return ParsedLine(model: nil, counters: nil, timestamp: timestamp)
        }

        let counters = TokenCounters(
            input: integerValue(for: "input_tokens", in: bytes),
            cached: integerValue(for: "cached_input_tokens", in: bytes),
            cacheWrite: integerValue(for: "cache_write_input_tokens", in: bytes),
            output: integerValue(for: "output_tokens", in: bytes)
        )
        return ParsedLine(model: nil, counters: counters, timestamp: timestamp)
    }

    private static func stringValue(for key: String, in bytes: [UInt8]) -> String? {
        guard let field = fieldStart(for: key, in: bytes) else { return nil }
        var index = field
        skipWhitespace(in: bytes, index: &index)
        guard index < bytes.count, bytes[index] == 0x3A else { return nil }
        index += 1
        skipWhitespace(in: bytes, index: &index)
        guard index < bytes.count, bytes[index] == 0x22 else { return nil }
        index += 1
        var output: [UInt8] = []
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                return String(bytes: output, encoding: .utf8)
            case 0x5C:
                guard index + 1 < bytes.count else { return nil }
                index += 1
                switch bytes[index] {
                case 0x22, 0x5C, 0x2F: output.append(bytes[index])
                case 0x6E: output.append(0x0A)
                case 0x72: output.append(0x0D)
                case 0x74: output.append(0x09)
                default: return nil
                }
            default:
                output.append(bytes[index])
            }
            index += 1
        }
        return nil
    }

    private static func integerValue(for key: String, in bytes: [UInt8]) -> Int64 {
        guard let field = fieldStart(for: key, in: bytes) else { return 0 }
        var index = field
        skipWhitespace(in: bytes, index: &index)
        guard index < bytes.count, bytes[index] == 0x3A else { return 0 }
        index += 1
        skipWhitespace(in: bytes, index: &index)
        var sign: Int64 = 1
        if index < bytes.count, bytes[index] == 0x2D {
            sign = -1
            index += 1
        }
        var value: Int64 = 0
        var sawDigit = false
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            sawDigit = true
            let digit = Int64(bytes[index] - 0x30)
            let (multiplied, multiplicationOverflow) = value.multipliedReportingOverflow(by: 10)
            let (added, additionOverflow) = multiplied.addingReportingOverflow(digit)
            if multiplicationOverflow || additionOverflow { return 0 }
            value = added
            index += 1
        }
        return sawDigit ? value * sign : 0
    }

    private static func fieldStart(for key: String, in bytes: [UInt8]) -> Int? {
        let marker = Array(("\"" + key + "\"").utf8)
        guard bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) {
            guard bytes[start..<start + marker.count].elementsEqual(marker) else { continue }
            // A quote escaped inside a prompt string is not a JSON field.
            if start > 0, bytes[start - 1] == 0x5C { continue }
            var index = start + marker.count
            skipWhitespace(in: bytes, index: &index)
            if index < bytes.count, bytes[index] == 0x3A {
                return index
            }
        }
        return nil
    }

    private static func contains(_ needle: [UInt8], in bytes: [UInt8]) -> Bool {
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        for start in 0...(bytes.count - needle.count) {
            if bytes[start..<start + needle.count].elementsEqual(needle) {
                return true
            }
        }
        return false
    }

    private static func skipWhitespace(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }

    private static func rates(for rawModel: String) -> Rates? {
        var model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("openai/") { model.removeFirst("openai/".count) }
        if model.count > 11 {
            let suffix = String(model.suffix(11))
            if Self.isDateSuffix(suffix) {
                model = String(model.dropLast(11))
            }
        }
        switch model {
        // Rates mirror CodexBar's local Codex cost table. Cache writes fall
        // back to ordinary input pricing for models without a separate rate.
        case "gpt-5.6", "gpt-5.6-sol":
            return Rates(input: 5, cached: 0.5, cacheWrite: 6.25, output: 30)
        case "gpt-5.6-terra":
            return Rates(input: 2, cached: 0.2, cacheWrite: 2.5, output: 12)
        case "gpt-5.6-luna":
            return Rates(input: 0.2, cached: 0.02, cacheWrite: 0.25, output: 1.2)
        case "gpt-6-astra":
            return Rates(input: 10, cached: 1, cacheWrite: 12.5, output: 50)
        case "gpt-5", "gpt-5-codex", "gpt-5.1", "gpt-5.1-codex":
            return Rates(input: 1.25, cached: 0.125, cacheWrite: 1.25, output: 10)
        default:
            return nil
        }
    }

    private static func isDateSuffix(_ suffix: String) -> Bool {
        let bytes = Array(suffix.utf8)
        guard bytes.count == 11,
              bytes[0] == 45, bytes[5] == 45, bytes[8] == 45 else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            [0, 5, 8].contains(index) || (48...57).contains(byte)
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
        var contributions: [CostContribution] = []
    }

    private struct CostContribution {
        let date: Date
        let model: String
        let amount: Decimal
        let pricedTokenCount: Int64
        let unpricedTokenCount: Int64
    }

    private struct CostAggregate {
        var amount: Decimal = .zero
        var pricedTokenCount: Int64 = 0
        var unpricedTokenCount: Int64 = 0

        mutating func add(_ contribution: CostContribution) {
            amount += contribution.amount
            pricedTokenCount += contribution.pricedTokenCount
            unpricedTokenCount += contribution.unpricedTokenCount
        }
    }

    private struct TokenCounters: Equatable {
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

        func delta(from previous: TokenCounters) -> TokenCounters? {
            guard input >= previous.input,
                  cached >= previous.cached,
                  cacheWrite >= previous.cacheWrite,
                  output >= previous.output else {
                return nil
            }
            return TokenCounters(
                input: input - previous.input,
                cached: cached - previous.cached,
                cacheWrite: cacheWrite - previous.cacheWrite,
                output: output - previous.output
            )
        }

        init(input: Int64, cached: Int64, cacheWrite: Int64, output: Int64) {
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
