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

enum CodexCostBucketGranularity: Sendable {
    case day
    case week
    case month

    var label: String {
        switch self {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        }
    }
}

enum CodexCostHistoryRange: String, CaseIterable, Codable, Defaults.Serializable, Hashable, Identifiable, Sendable {
    case last7Days
    case last30Days
    case last90Days
    case lastYear
    case allAvailable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 3 months"
        case .lastYear: "Last year"
        case .allAvailable: "All available"
        }
    }

    var shortLabel: String {
        switch self {
        case .last7Days: "7 days"
        case .last30Days: "30 days"
        case .last90Days: "3 months"
        case .lastYear: "1 year"
        case .allAvailable: "All available"
        }
    }

    var durationDays: Int {
        switch self {
        case .last7Days: 7
        case .last30Days: 30
        case .last90Days: 90
        case .lastYear: 365
        // A century is effectively unbounded for local Codex history while
        // keeping the request representable as a bounded scan.
        case .allAvailable: 36_500
        }
    }

    /// Keep the chart legible as the selected history grows: short ranges
    /// retain one bar per day, while longer ranges roll up to weeks or months.
    var bucketGranularity: CodexCostBucketGranularity {
        switch self {
        case .last7Days, .last30Days: .day
        case .last90Days: .week
        case .lastYear, .allAvailable: .month
        }
    }

    func interval(endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        let end = now
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(durationDays - 1), to: today) ?? today
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(0.001)))
    }
}

enum CodexQuotaWindowDisplayMode: String, CaseIterable, Codable, Defaults.Serializable, Identifiable, Sendable {
    case automatic
    case weeklyOnly
    case allAvailable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .weeklyOnly: "Weekly only"
        case .allAvailable: "All available"
        }
    }

    var description: String {
        switch self {
        case .automatic:
            "Use the reset windows attached to your Codex plan. Model-specific limits are kept out of the main quota view."
        case .weeklyOnly:
            "Show only the weekly reset window, even when your account also exposes a 5-hour window."
        case .allAvailable:
            "Show every standard reset window returned for the account."
        }
    }
}

enum CodexResetForecastDisplayMode: String, CaseIterable, Codable, Defaults.Serializable, Identifiable, Sendable {
    case both
    case twentyFourHours
    case fortyEightHours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: "24h + 48h"
        case .twentyFourHours: "24-hour"
        case .fortyEightHours: "48-hour"
        }
    }

    var description: String {
        switch self {
        case .both:
            "Show both reset probabilities when the source provides them."
        case .twentyFourHours:
            "Show only the chance of a reset in the next 24 hours."
        case .fortyEightHours:
            "Show only the chance of a reset in the next 48 hours."
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

/// The usage RPC identifies the broad plan family, but it does not reliably
/// distinguish the two Pro tiers. Keep that ambiguity visible instead of
/// silently comparing a Pro account against the wrong monthly price.
enum CodexPlanPricing: String, CaseIterable, Codable, Defaults.Serializable, Identifiable, Sendable {
    case automatic
    case plus
    case pro100
    case pro200
    case noFixedPrice

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .plus: "Plus · $20/month"
        case .pro100: "Pro 5x · $100/month"
        case .pro200: "Pro 20x · $200/month"
        case .noFixedPrice: "No fixed monthly price"
        }
    }

    var planLabel: String {
        switch self {
        case .automatic: "Automatic"
        case .plus: "Plus"
        case .pro100: "Pro 5x"
        case .pro200: "Pro 20x"
        case .noFixedPrice: "Custom"
        }
    }

    var monthlyPrice: Decimal? {
        switch self {
        case .automatic, .noFixedPrice:
            nil
        case .plus:
            20
        case .pro100:
            100
        case .pro200:
            200
        }
    }
}

struct CodexPlanInfo: Equatable, Sendable {
    let planLabel: String
    let monthlyPrice: Decimal?
    let isDetected: Bool
    let isPriceAmbiguous: Bool

    var monthlyPriceLabel: String? {
        guard let monthlyPrice else { return nil }
        return NSDecimalNumber(decimal: monthlyPrice).doubleValue
            .formatted(.currency(code: "USD")) + "/month"
    }

    /// Resolve the server-provided family and an optional user-selected tier
    /// into the pricing context used by the API-equivalent display.
    static func resolve(planType: String?, pricing: CodexPlanPricing) -> Self {
        if pricing != .automatic {
            return Self(
                planLabel: pricing.planLabel,
                monthlyPrice: pricing.monthlyPrice,
                isDetected: !pricingEqualsNoFixedPrice(pricing),
                isPriceAmbiguous: false
            )
        }

        guard let rawPlanType = planType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPlanType.isEmpty
        else {
            return Self(
                planLabel: "Plan unavailable",
                monthlyPrice: nil,
                isDetected: false,
                isPriceAmbiguous: false
            )
        }

        let normalized = rawPlanType
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        if normalized.contains("pro100") || normalized.contains("pro5x") || normalized == "prolite" {
            return Self(planLabel: "Pro 5x", monthlyPrice: 100, isDetected: true, isPriceAmbiguous: false)
        }
        if normalized.contains("pro200") || normalized.contains("pro20x") {
            return Self(planLabel: "Pro 20x", monthlyPrice: 200, isDetected: true, isPriceAmbiguous: false)
        }

        switch normalized {
        case "plus", "chatgptplus":
            return Self(planLabel: "Plus", monthlyPrice: 20, isDetected: true, isPriceAmbiguous: false)
        case "pro", "chatgptpro", "codexpro":
            // Codex's current plan identifiers use `pro` for the 20x tier and
            // `prolite` for the 5x tier. Keep the broad legacy response
            // conservative when no tier identifier is available.
            return Self(planLabel: "Pro", monthlyPrice: nil, isDetected: true, isPriceAmbiguous: true)
        case "free", "freeplan":
            return Self(planLabel: "Free", monthlyPrice: nil, isDetected: true, isPriceAmbiguous: false)
        case "go", "chatgptgo":
            return Self(planLabel: "Go", monthlyPrice: nil, isDetected: true, isPriceAmbiguous: false)
        case "team", "business", "chatgptteam", "chatgptbusiness":
            return Self(planLabel: "Business", monthlyPrice: nil, isDetected: true, isPriceAmbiguous: false)
        case "enterprise", "chatgptenterprise":
            return Self(planLabel: "Enterprise", monthlyPrice: nil, isDetected: true, isPriceAmbiguous: false)
        default:
            return Self(
                planLabel: rawPlanType.capitalized,
                monthlyPrice: nil,
                isDetected: true,
                isPriceAmbiguous: false
            )
        }
    }

    /// Compare the selected local API-equivalent history with the monthly
    /// subscription cost prorated over that same period. A 30-day window
    /// therefore gives the expected example: $3,000 / $100 = 30×.
    func multiplier(
        for estimate: CodexCostEstimate,
        historyRange: CodexCostHistoryRange
    ) -> Double? {
        guard let monthlyPrice,
              monthlyPrice > 0,
              estimate.pricedTokenCount > 0,
              estimate.measurement.amount > 0
        else { return nil }

        let comparisonDuration: TimeInterval
        if historyRange == .allAvailable,
           let first = estimate.dailyBreakdown.map(\.date).min(),
           let last = estimate.dailyBreakdown.map(\.date).max() {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: first)
            let end = calendar.startOfDay(for: last).addingTimeInterval(86_400)
            comparisonDuration = max(86_400, end.timeIntervalSince(start))
        } else {
            comparisonDuration = max(86_400, estimate.measurement.interval.duration)
        }

        let monthlyCost = NSDecimalNumber(decimal: monthlyPrice).doubleValue
        let baseline = monthlyCost * comparisonDuration / (30 * 86_400)
        guard baseline.isFinite, baseline > 0 else { return nil }

        let amount = NSDecimalNumber(decimal: estimate.measurement.amount).doubleValue
        let multiplier = amount / baseline
        return multiplier.isFinite && multiplier > 0 ? multiplier : nil
    }

    private static func pricingEqualsNoFixedPrice(_ pricing: CodexPlanPricing) -> Bool {
        pricing == .noFixedPrice
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
    /// A plan identifier found in local Codex rollout metadata. This can be
    /// more specific than the app-server's broad family (`pro`/`plus`).
    let planType: String?
}

struct CodexResetForecast: Equatable, Sendable {
    static let sourceName = "Will Codex Reset?"
    static let sourceURL = URL(string: "https://willcodexreset.com/")!
    static let endpointURL = URL(string: "https://willcodexreset.com/api/reset-radar")!

    let probability24h: Double?
    let probability48h: Double?
    let resetAnnounced: Bool
    let verdictCode: String?
    let verdictLabel: String?
    let sourceStale: Bool
    let fetchedAt: Date?
    let nextRefreshAt: Date?

    var score: Double {
        probability48h ?? probability24h ?? 0
    }

    var horizonHours: Int {
        probability48h == nil ? 24 : 48
    }
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
