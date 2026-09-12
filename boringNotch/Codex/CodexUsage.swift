// Portions adapted from Cowlick (MIT).
// Copyright (c) 2026 Cowlick contributors.

import Defaults
import Foundation

enum CodexUsageMetric: String, CaseIterable, Codable, Defaults.Serializable, Identifiable, Sendable {
    case remaining
    case used

    var id: String { rawValue }

    var label: String {
        switch self {
        case .remaining: "Remaining"
        case .used: "Used"
        }
    }

    var accessibilityLabel: String { rawValue }

    func displayedPercent(forUsedPercent usedPercent: Double) -> Double? {
        guard usedPercent.isFinite else { return nil }
        let clamped = usedPercent.clamped(to: 0...100)
        return self == .used ? clamped : 100 - clamped
    }
}

enum CodexQuotaWindowPreference: String, CaseIterable, Codable, Defaults.Serializable, Identifiable, Sendable {
    case fiveHour
    case weekly

    var id: String { rawValue }

    var durationMinutes: Int {
        switch self {
        case .fiveHour: 300
        case .weekly: 10_080
        }
    }

    var label: String {
        switch self {
        case .fiveHour: "5-hour window"
        case .weekly: "Weekly window"
        }
    }

    var shortLabel: String {
        switch self {
        case .fiveHour: "5-hour"
        case .weekly: "Weekly"
        }
    }
}

struct CodexUsageLimit: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let usedPercent: Double
    let resetsAt: Date?
    let windowDurationMinutes: Int?

    var remainingPercent: Double {
        displayedPercent(for: .remaining)
    }

    func displayedPercent(for metric: CodexUsageMetric) -> Double {
        metric.displayedPercent(forUsedPercent: usedPercent) ?? 0
    }

    /// Maps the two standard Codex reset windows even when the API omits a
    /// duration on a legacy response and leaves only a human-readable name.
    var standardWindow: CodexQuotaWindowPreference? {
        if windowDurationMinutes == CodexQuotaWindowPreference.fiveHour.durationMinutes {
            return .fiveHour
        }
        if windowDurationMinutes == CodexQuotaWindowPreference.weekly.durationMinutes {
            return .weekly
        }

        let normalizedName = name.lowercased()
        if normalizedName.contains("5-hour") || normalizedName.contains("5 hour") {
            return .fiveHour
        }
        if normalizedName.contains("weekly")
            || normalizedName.contains("7-day")
            || normalizedName.contains("7 day")
        {
            return .weekly
        }
        return nil
    }
}

struct CodexUsageSnapshot: Equatable, Sendable {
    let limits: [CodexUsageLimit]
    let planType: String?
    let fetchedAt: Date

    var primaryLimit: CodexUsageLimit? { limits.first }

    var fiveHourLimit: CodexUsageLimit? {
        limits.first { $0.standardWindow == .fiveHour }
    }

    var weeklyLimit: CodexUsageLimit? {
        limits.first { $0.standardWindow == .weekly }
    }

    var availableWindowPreferences: [CodexQuotaWindowPreference] {
        CodexQuotaWindowPreference.allCases.filter { preference in
            limits.contains { $0.standardWindow == preference }
        }
    }

    var windowAvailability: CodexQuotaWindowAvailability {
        switch (fiveHourLimit != nil, weeklyLimit != nil) {
        case (false, true): .weeklyOnly
        case (true, true): .fiveHourAndWeekly
        case (true, false): .fiveHourOnly
        case (false, false): .custom
        }
    }
}

enum CodexQuotaWindowAvailability: Equatable, Sendable {
    case unknown
    case weeklyOnly
    case fiveHourAndWeekly
    case fiveHourOnly
    case custom

    var label: String {
        switch self {
        case .unknown: "Detecting windows…"
        case .weeklyOnly: "Weekly only"
        case .fiveHourAndWeekly: "5-hour + weekly"
        case .fiveHourOnly: "5-hour only"
        case .custom: "Custom windows"
        }
    }

    var description: String {
        switch self {
        case .unknown:
            "Notch will use the windows returned by your Codex account."
        case .weeklyOnly:
            "This account exposes a weekly reset window. Notch will show and pace that window only."
        case .fiveHourAndWeekly:
            "This account exposes both reset windows. Notch will show both and use your preferred one for the compact notch."
        case .fiveHourOnly:
            "This account exposes a 5-hour reset window but no weekly window. Notch will show that window only."
        case .custom:
            "This account returned a non-standard window. Notch will show the available data without inventing a 5-hour or weekly lane."
        }
    }
}

enum CodexQuotaPaceStatus: String, Codable, Sendable {
    case reserve
    case onPace
    case deficit
}

struct CodexQuotaExhaustionForecast: Equatable, Codable, Sendable {
    let estimatedAt: Date
    let resetsAt: Date

    var willLastThroughReset: Bool { estimatedAt >= resetsAt }
}

struct CodexQuotaPace: Equatable, Codable, Sendable {
    let expectedUsedPercent: Double
    let actualUsedPercent: Double
    /// Positive values are reserve; negative values are deficit.
    let balancePercent: Double
    let status: CodexQuotaPaceStatus
    let exhaustionForecast: CodexQuotaExhaustionForecast?

    var reservePercent: Double { max(balancePercent, 0) }
    var deficitPercent: Double { max(-balancePercent, 0) }

    func expectedDisplayedPercent(for metric: CodexUsageMetric) -> Double {
        metric.displayedPercent(forUsedPercent: expectedUsedPercent) ?? 0
    }
}

enum CodexQuotaPaceCalculator {
    static let minimumElapsedFraction = 0.03
    static let minimumObservedUsagePercent = 1.0

    static func pace(
        for limit: CodexUsageLimit,
        observedAt: Date? = nil,
        now: Date = .init()
    ) -> CodexQuotaPace? {
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

        let expected = elapsedFraction * 100
        let actual = limit.usedPercent.clamped(to: 0...100)
        let balance = expected - actual
        let status: CodexQuotaPaceStatus
        if abs(balance) < 0.000_001 {
            status = .onPace
        } else if balance > 0 {
            status = .reserve
        } else {
            status = .deficit
        }

        let observationDate = observedAt ?? now
        let observedElapsed = duration - resetsAt.timeIntervalSince(observationDate)
        let exhaustionForecast: CodexQuotaExhaustionForecast? =
            if actual >= minimumObservedUsagePercent {
                forecast(
                    actualUsedPercent: actual,
                    elapsed: observedElapsed,
                    observedAt: observationDate,
                    resetsAt: resetsAt
                )
            } else {
                nil
            }

        return CodexQuotaPace(
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            balancePercent: balance,
            status: status,
            exhaustionForecast: exhaustionForecast
        )
    }

    private static func forecast(
        actualUsedPercent: Double,
        elapsed: TimeInterval,
        observedAt: Date,
        resetsAt: Date
    ) -> CodexQuotaExhaustionForecast? {
        let burnRate = actualUsedPercent / elapsed
        guard burnRate.isFinite, burnRate > 0 else { return nil }
        let timeToEmpty = (100 - actualUsedPercent) / burnRate
        guard timeToEmpty.isFinite, timeToEmpty >= 0 else { return nil }
        return CodexQuotaExhaustionForecast(
            estimatedAt: observedAt.addingTimeInterval(timeToEmpty),
            resetsAt: resetsAt
        )
    }
}

struct CodexCostMeasurement: Equatable, Sendable {
    let amount: Decimal
    let currency: String
    let pricingAsOf: Date?
    let interval: DateInterval
    let partial: Bool
}

struct CodexCostDay: Identifiable, Equatable, Sendable {
    let date: Date
    let amount: Decimal
    let pricedTokenCount: Int64
    let unpricedTokenCount: Int64

    var id: Date { date }
    var totalTokenCount: Int64 { pricedTokenCount + unpricedTokenCount }
}

struct CodexCostModel: Identifiable, Equatable, Sendable {
    let model: String
    let amount: Decimal
    let pricedTokenCount: Int64
    let unpricedTokenCount: Int64

    var id: String { model }
    var totalTokenCount: Int64 { pricedTokenCount + unpricedTokenCount }
}

struct CodexCostEstimate: Equatable, Sendable {
    let measurement: CodexCostMeasurement
    let pricedTokenCount: Int64
    let unpricedTokenCount: Int64
    let dailyBreakdown: [CodexCostDay]
    let modelBreakdown: [CodexCostModel]
    let refreshedAt: Date
}

struct CodexResetForecast: Equatable, Sendable {
    static let sourceName = "Will Codex Reset?"
    static let sourceURL = URL(string: "https://willcodexreset.com/")!
    static let endpointURL = URL(string: "https://willcodexreset.com/api/reset-radar")!

    let score: Double
    let resetAnnounced: Bool
    let verdictCode: String?
    let verdictLabel: String?
    let horizonHours: Int
    let sourceStale: Bool
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
