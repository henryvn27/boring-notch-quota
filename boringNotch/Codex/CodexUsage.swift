// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Foundation

struct CodexUsageLimit: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let usedPercent: Double
    let resetsAt: Date?
    let windowDurationMinutes: Int?

    var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }
}

struct CodexUsageSnapshot: Equatable, Sendable {
    let limits: [CodexUsageLimit]
    let planType: String?
    let fetchedAt: Date

    var primaryLimit: CodexUsageLimit? { limits.first }
}

struct CodexQuotaPace: Equatable, Sendable {
    let expectedUsedPercent: Double
    let actualUsedPercent: Double
    /// Positive values mean reserve; negative values mean a deficit against an even pace.
    let balancePercent: Double
    let exhaustionAt: Date?
}

enum CodexQuotaPaceCalculator {
    static let minimumElapsedFraction = 0.03

    static func pace(for limit: CodexUsageLimit, observedAt: Date, now: Date = Date()) -> CodexQuotaPace? {
        guard limit.usedPercent.isFinite,
              let durationMinutes = limit.windowDurationMinutes,
              durationMinutes > 0,
              let resetsAt = limit.resetsAt else {
            return nil
        }

        let duration = TimeInterval(durationMinutes * 60)
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0, remaining <= duration else { return nil }

        let elapsedFraction = (1 - remaining / duration).clamped(to: 0...1)
        guard elapsedFraction >= minimumElapsedFraction else { return nil }

        let actual = limit.usedPercent.clamped(to: 0...100)
        let expected = elapsedFraction * 100
        let elapsedAtObservation = max(1, observedAt.timeIntervalSince(now) + (duration - remaining))
        let exhaustionAt: Date?
        if actual > 0, elapsedAtObservation > 0 {
            let burnRate = actual / elapsedAtObservation
            let timeToEmpty = (100 - actual) / burnRate
            exhaustionAt = timeToEmpty.isFinite && timeToEmpty >= 0
                ? observedAt.addingTimeInterval(timeToEmpty)
                : nil
        } else {
            exhaustionAt = nil
        }

        return CodexQuotaPace(
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            balancePercent: expected - actual,
            exhaustionAt: exhaustionAt
        )
    }
}

enum CodexUsageMetric: String, Sendable {
    case remaining
    case used
}

struct CodexCostMeasurement: Equatable, Sendable {
    let amount: Decimal
    let currency: String
    let pricingAsOf: Date?
    let interval: DateInterval
    let partial: Bool
}

struct CodexCostEstimate: Equatable, Sendable {
    let measurement: CodexCostMeasurement
    let pricedTokenCount: Int64
    let unpricedTokenCount: Int64
    let refreshedAt: Date
}

struct CodexResetForecast: Equatable, Sendable {
    static let sourceName = "Will Codex Reset?"
    static let sourceURL = URL(string: "https://www.willcodexquotareset.com")!
    static let endpointURL = URL(string: "https://www.willcodexquotareset.com/api/forecast")!

    let score: Double
    let resetAnnounced: Bool
    let fetchedAt: Date?
    let nextRefreshAt: Date?
}

enum CodexTimeFormatter {
    static func relative(_ date: Date, from reference: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(reference)
        let future = seconds > 0
        let interval = abs(seconds)
        let value: Int
        let unit: String
        if interval >= 86_400 {
            value = max(1, Int((interval / 86_400).rounded()))
            unit = value == 1 ? "day" : "days"
        } else if interval >= 3_600 {
            value = max(1, Int((interval / 3_600).rounded()))
            unit = value == 1 ? "hour" : "hours"
        } else if interval >= 60 {
            value = max(1, Int((interval / 60).rounded()))
            unit = value == 1 ? "minute" : "minutes"
        } else {
            value = max(1, Int(interval.rounded()))
            unit = value == 1 ? "second" : "seconds"
        }
        if interval < 5 { return "just now" }
        return future ? "in \(value) \(unit)" : "\(value) \(unit) ago"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(1, Int(max(0, interval) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    static func resetDate(_ date: Date, from reference: Date = Date()) -> String {
        let interval = max(0, date.timeIntervalSince(reference))
        return duration(interval)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
