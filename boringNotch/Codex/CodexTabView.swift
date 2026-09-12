import Defaults
import SwiftUI

struct CodexTabView: View {
    @ObservedObject private var manager = CodexUsageManager.shared
    @State private var presentationDate = Date()
    @Default(.codexUsageMetric) private var usageMetric
    @Default(.codexPreferredWindow) private var preferredWindow
    @Default(.codexShowPace) private var showPace
    @Default(.codexShowCostEstimate) private var showCostEstimate
    @Default(.codexShowResetForecast) private var showResetForecast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                if showCostEstimate {
                    apiCostCard
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if showResetForecast {
                    forecastCard
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            quotaGraphs
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, date in
                        presentationDate = date
                    }
            }
        }
        .onAppear {
            manager.start()
            manager.refreshNow()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex quota and usage")
    }

    private var quotaGraphs: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Usage")
                    .font(.caption.weight(.semibold))
                if manager.usageError != nil {
                    Text("Stale")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if let snapshot = manager.snapshot {
                    Text(snapshot.windowAvailability.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let snapshot = manager.snapshot {
                let limits = Array(visibleQuotaLimits(snapshot.limits).prefix(2))
                if limits.count == 1, let limit = limits.first {
                    quotaWindow(limit, observedAt: snapshot.fetchedAt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(limits) { limit in
                            quotaWindow(limit, observedAt: snapshot.fetchedAt)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else if let error = manager.usageError {
                unavailableRow(error)
            } else {
                loadingRow("Reading local quota…")
            }
        }
    }

    private func quotaWindow(_ limit: CodexUsageLimit, observedAt: Date) -> some View {
        let pace = showPace
            ? CodexQuotaPaceCalculator.pace(for: limit, observedAt: observedAt, now: presentationDate)
            : nil

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(shortQuotaName(limit.name))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 1)
                Text("\(Int(limit.displayedPercent(for: usageMetric).rounded()))%")
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }

            CodexQuotaMeter(
                displayedPercent: limit.displayedPercent(for: usageMetric),
                expectedPercent: pace?.expectedDisplayedPercent(for: usageMetric)
            )
            .frame(height: 5)

            if let pace {
                Text(compactPaceSummary(pace))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(CodexQuotaPresentation.paceColor(pace))
                    .lineLimit(1)
            }
            if let resetsAt = limit.resetsAt {
                Text(CodexTimeFormatter.resetDate(resetsAt, from: presentationDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(limitAccessibilityLabel(limit, pace: pace))
    }

    private func compactPaceSummary(_ pace: CodexQuotaPace) -> String {
        let points = Int(abs(pace.balancePercent).rounded())
        switch pace.status {
        case .reserve:
            return "+\(points)%"
        case .onPace:
            return "+0%"
        case .deficit:
            return "-\(points)%"
        }
    }

    private var apiCostCard: some View {
        CodexCard(
            title: "API equivalent",
            subtitle: "This Mac · 30 days"
        ) {
            if let estimate = manager.costEstimate {
                if estimate.pricedTokenCount > 0 {
                    Text(estimate.measurement.amount.formatted(.currency(code: estimate.measurement.currency)))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .accessibilityLabel("API equivalent \(estimate.measurement.amount.formatted(.currency(code: estimate.measurement.currency)))")
                } else {
                    Text("—")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .accessibilityLabel("No priced local usage")
                }

            } else if let error = manager.costError {
                unavailableRow(error)
            } else {
                loadingRow("Reading local cost…")
            }

        }
    }

    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let forecast = manager.forecast {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Int(forecast.score.rounded()))%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("chance of reset · next \(forecast.horizonHours)h")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if forecast.resetAnnounced {
                    Text("Reset announced")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                } else if forecast.sourceStale {
                    Text("Stale signal")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else if let error = manager.forecastError {
                unavailableRow(error)
            } else {
                loadingRow("Loading forecast…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chance of reset")
    }

    private func loadingRow(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func unavailableRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func visibleQuotaLimits(_ limits: [CodexUsageLimit]) -> [CodexUsageLimit] {
        var result: [CodexUsageLimit] = []
        let sorted = limits.sorted { ($0.windowDurationMinutes ?? Int.max) < ($1.windowDurationMinutes ?? Int.max) }

        func limit(for preference: CodexQuotaWindowPreference) -> CodexUsageLimit? {
            let candidates = sorted.filter { $0.standardWindow == preference }
            return candidates.first(where: {
                preference != .weekly || !$0.name.localizedCaseInsensitiveContains("spark")
            }) ?? candidates.first
        }

        let hasFiveHour = sorted.contains { $0.standardWindow == .fiveHour }
        let hasWeekly = sorted.contains { $0.standardWindow == .weekly }

        // A weekly-only account gets one full-width graph. Do not fill the
        // second lane with an unrelated bucket or an invented 5-hour value.
        if hasWeekly && !hasFiveHour, let weekly = limit(for: .weekly) {
            return [weekly]
        }
        if hasFiveHour && !hasWeekly, let fiveHour = limit(for: .fiveHour) {
            return [fiveHour]
        }

        if let preferred = limit(for: preferredWindow) {
            result.append(preferred)
        }
        let secondaryWindow: CodexQuotaWindowPreference = preferredWindow == .fiveHour ? .weekly : .fiveHour
        if let secondary = limit(for: secondaryWindow), !result.contains(where: { $0.id == secondary.id }) {
            result.append(secondary)
        }
        let knownIDs = Set(result.map(\.id))
        result.append(contentsOf: sorted.filter {
            !knownIDs.contains($0.id)
                && $0.windowDurationMinutes != 300
                && $0.windowDurationMinutes != 10_080
        })
        return result
    }

    private func shortQuotaName(_ name: String) -> String {
        name.components(separatedBy: " · ").first ?? name
    }

    private func limitAccessibilityLabel(_ limit: CodexUsageLimit, pace: CodexQuotaPace?) -> String {
        let displayed = Int(limit.displayedPercent(for: usageMetric).rounded())
        var result = "\(limit.name), \(displayed) percent \(usageMetric.accessibilityLabel)"
        if let pace {
            let points = Int(abs(pace.balancePercent).rounded())
            switch pace.status {
            case .reserve:
                result += ", \(points) percentage points in reserve"
            case .onPace:
                result += ", on pace"
            case .deficit:
                result += ", \(points) percentage points in deficit"
            }
            if let forecast = pace.exhaustionForecast {
                result += forecast.willLastThroughReset
                    ? ", should last through reset"
                    : ", projected to run out before reset"
            }
        }
        if let resetsAt = limit.resetsAt {
            result += ", resets in \(CodexTimeFormatter.resetDate(resetsAt, from: presentationDate))"
        }
        return result
    }
}

private struct CodexCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            content()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityAction(named: "Refresh \(title)") {
            CodexUsageManager.shared.refreshNow()
        }
    }
}

enum CodexIdleUsageLayout {
    // Reserve a real four-character label lane for "-100%" on either wing.
    // The zero-padded geometry is still four points narrower overall than the
    // original 48pt + 3pt-per-side layout.
    static let sideWidth: CGFloat = 50
    static let sidePadding: CGFloat = 1
    static let totalWingWidth: CGFloat = (sideWidth + (sidePadding * 2)) * 2

    static func compactCenterWidth(for notchWidth: CGFloat) -> CGFloat {
        notchWidth
    }

    static func totalWidth(for notchWidth: CGFloat) -> CGFloat {
        compactCenterWidth(for: notchWidth) + totalWingWidth
    }
}

struct CodexIdleUsageView: View {
    @ObservedObject private var manager = CodexUsageManager.shared
    @Default(.codexPreferredWindow) private var preferredWindow
    @Default(.codexShowPace) private var showPace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let notchWidth: CGFloat
    let height: CGFloat
    let action: () -> Void

    @State private var presentationDate = Date()

    private var limit: CodexUsageLimit? {
        guard let limits = manager.snapshot?.limits else { return nil }
        return CodexQuotaPresentation.primaryLimit(from: limits, preferredWindow: preferredWindow)
    }

    private var pace: CodexQuotaPace? {
        guard showPace, let limit, let snapshot = manager.snapshot else { return nil }
        return CodexQuotaPaceCalculator.pace(
            for: limit,
            observedAt: snapshot.fetchedAt,
            now: presentationDate
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(remainingLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: CodexIdleUsageLayout.sideWidth, alignment: .trailing)
                    .padding(.horizontal, CodexIdleUsageLayout.sidePadding)

                Color.black
                    .frame(width: CodexIdleUsageLayout.compactCenterWidth(for: notchWidth))

                Text(balanceLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(balanceColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: CodexIdleUsageLayout.sideWidth, alignment: .leading)
                    .padding(.horizontal, CodexIdleUsageLayout.sidePadding)
            }
            .frame(width: CodexIdleUsageLayout.totalWidth(for: notchWidth), height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(CodexCompactButtonStyle(reduceMotion: reduceMotion))
        .onAppear {
            manager.start()
        }
        .background {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, date in
                        presentationDate = date
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open Codex quota")
    }

    private var remainingLabel: String {
        guard let limit else { return manager.isRefreshing ? "…" : "—" }
        return "\(Int(limit.remainingPercent.rounded()))%"
    }

    private var balanceLabel: String {
        guard showPace, let pace else { return manager.isRefreshing ? "…" : "—" }
        let points = Int(abs(pace.balancePercent).rounded())
        return pace.status == .deficit ? "-\(points)%" : "+\(points)%"
    }

    private var balanceColor: Color {
        guard let pace else { return .secondary }
        return CodexQuotaPresentation.paceColor(pace)
    }

    private var accessibilityLabel: String {
        guard let limit else {
            return manager.isRefreshing ? "Refreshing Codex usage" : "Codex usage unavailable"
        }
        let percent = Int(limit.remainingPercent.rounded())
        var result = "Codex, \(percent) percent remaining"
        if let pace {
            result += ", " + CodexQuotaPresentation.paceSummary(pace, relativeTo: presentationDate)
        }
        if let resetsAt = limit.resetsAt {
            result += ", resets in \(CodexTimeFormatter.resetDate(resetsAt, from: presentationDate))"
        }
        return result
    }
}

/// The pace wing stays available when music owns the closed-notch center.
/// It intentionally shares the same math, labels, and semantic colors as the
/// idle Codex readout so switching modes never changes what the number means.
struct CodexCompactPaceWing: View {
    @ObservedObject private var manager = CodexUsageManager.shared
    @Default(.codexPreferredWindow) private var preferredWindow
    @Default(.codexShowPace) private var showPace

    let height: CGFloat
    @State private var presentationDate = Date()

    private var limit: CodexUsageLimit? {
        guard let limits = manager.snapshot?.limits else { return nil }
        return CodexQuotaPresentation.primaryLimit(from: limits, preferredWindow: preferredWindow)
    }

    private var pace: CodexQuotaPace? {
        guard showPace, let limit, let snapshot = manager.snapshot else { return nil }
        return CodexQuotaPaceCalculator.pace(
            for: limit,
            observedAt: snapshot.fetchedAt,
            now: presentationDate
        )
    }

    var body: some View {
        Text(balanceLabel)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(balanceColor)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: CodexIdleUsageLayout.sideWidth, height: height, alignment: .leading)
            .padding(.horizontal, CodexIdleUsageLayout.sidePadding)
            .onAppear {
                manager.start()
            }
            .background {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Color.clear
                        .onChange(of: timeline.date) { _, date in
                            presentationDate = date
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    private var balanceLabel: String {
        guard showPace, let pace else { return manager.isRefreshing ? "…" : "—" }
        let points = Int(abs(pace.balancePercent).rounded())
        return pace.status == .deficit ? "-\(points)%" : "+\(points)%"
    }

    private var balanceColor: Color {
        guard let pace else { return .secondary }
        return CodexQuotaPresentation.paceColor(pace)
    }

    private var accessibilityLabel: String {
        guard let pace else { return "Codex pace unavailable" }
        return "Codex pace, " + CodexQuotaPresentation.paceSummary(pace, relativeTo: presentationDate)
    }
}

private enum CodexQuotaPresentation {
    static func primaryLimit(
        from limits: [CodexUsageLimit],
        preferredWindow: CodexQuotaWindowPreference
    ) -> CodexUsageLimit? {
        let sorted = limits.sorted { ($0.windowDurationMinutes ?? Int.max) < ($1.windowDurationMinutes ?? Int.max) }
        let preferred = sorted.filter { $0.standardWindow == preferredWindow }
        if let preferred = preferred.first(where: {
            preferredWindow != .weekly || !$0.name.localizedCaseInsensitiveContains("spark")
        }) {
            return preferred
        }
        if let weekly = sorted.first(where: {
            $0.standardWindow == .weekly
                && !$0.name.localizedCaseInsensitiveContains("spark")
        }) {
            return weekly
        }
        return sorted.first
    }

    static func paceSummary(_ pace: CodexQuotaPace, relativeTo referenceDate: Date) -> String {
        let points = Int(abs(pace.balancePercent).rounded())
        let balance: String
        switch pace.status {
        case .reserve:
            balance = "\(points) pp reserve"
        case .onPace:
            balance = "On pace"
        case .deficit:
            balance = "\(points) pp deficit"
        }

        guard let forecast = pace.exhaustionForecast else { return balance }
        let forecastSummary: String
        if forecast.willLastThroughReset {
            forecastSummary = "Should last through reset"
        } else {
            let timeToEmpty = forecast.estimatedAt.timeIntervalSince(referenceDate)
            forecastSummary = timeToEmpty < 60
                ? "Runs out in under 1m"
                : "Runs out in \(CodexTimeFormatter.duration(timeToEmpty))"
        }
        return "\(forecastSummary) · \(balance)"
    }

    static func paceColor(_ pace: CodexQuotaPace) -> Color {
        switch pace.status {
        case .reserve, .onPace:
            return .green
        case .deficit:
            return pace.deficitPercent <= 15 ? .yellow : .red
        }
    }
}

private struct CodexCompactButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1, anchor: .top)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(
                reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}

private struct CodexQuotaMeter: View {
    let displayedPercent: Double
    let expectedPercent: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.16))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * fraction(displayedPercent))

                if let expectedPercent {
                    Capsule()
                        .fill(.primary.opacity(0.78))
                        .frame(width: 2, height: 8)
                        .position(
                            x: markerPosition(width: geometry.size.width, percent: expectedPercent),
                            y: geometry.size.height / 2
                        )
                }
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Quota usage")
        .accessibilityHidden(true)
    }

    private func fraction(_ percent: Double) -> CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100)
    }

    private func markerPosition(width: CGFloat, percent: Double) -> CGFloat {
        guard width > 2 else { return width / 2 }
        return min(max(width * fraction(percent), 1), width - 1)
    }
}
