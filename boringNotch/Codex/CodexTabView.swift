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
            header

            HStack(alignment: .top, spacing: 7) {
                quotaCard
                if showCostEstimate {
                    apiCostCard
                }
                if showResetForecast {
                    forecastCard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex")
                    .font(.headline.weight(.semibold))
                Text("Local quota, cost, and reset signal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                manager.refreshNow()
            } label: {
                CodexRefreshIndicator(isRefreshing: manager.isRefreshing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh Codex data")
            .accessibilityLabel("Refresh Codex data")
        }
    }

    private var quotaCard: some View {
        CodexCard(
            title: "Quota",
            subtitle: "From the local Codex app",
            isRefreshing: manager.isOfficialRefreshing,
            action: { manager.refreshNow() }
        ) {
            if let snapshot = manager.snapshot {
                Text(officialFreshness(snapshot))
                    .font(.caption2)
                    .foregroundStyle(manager.usageError == nil ? Color.secondary : Color.orange)

                HStack(alignment: .top, spacing: 7) {
                    ForEach(Array(visibleQuotaLimits(snapshot.limits).prefix(2))) { limit in
                        quotaWindow(limit, observedAt: snapshot.fetchedAt)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if manager.usageError != nil {
                    Label("Showing the last quota", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
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
            return "+\(points)% banked"
        case .onPace:
            return "On pace"
        case .deficit:
            return "-\(points)% deficit"
        }
    }

    private var apiCostCard: some View {
        CodexCard(
            title: "API equivalent",
            subtitle: "This Mac · 30 days",
            isRefreshing: manager.isCostRefreshing,
            action: { manager.refreshNow() }
        ) {
            if let estimate = manager.costEstimate {
                if estimate.pricedTokenCount > 0 {
                    Text(estimate.measurement.amount.formatted(.currency(code: estimate.measurement.currency)))
                        .font(.title2.weight(.semibold).monospacedDigit())
                } else {
                    Text("—")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text(estimate.unpricedTokenCount > 0
                        ? "No priced local usage"
                        : "No local token counters found")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("Updated \(CodexTimeFormatter.relative(estimate.refreshedAt, from: presentationDate))")
                    .font(.caption2)
                    .foregroundStyle(manager.costError == nil ? Color.secondary : Color.orange)

                if estimate.measurement.partial || estimate.unpricedTokenCount > 0 {
                    Label("Partial local estimate", systemImage: "circle.dashed")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                if let pricingAsOf = estimate.measurement.pricingAsOf {
                    Text("Rates as of \(pricingAsOf.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let error = manager.costError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            } else if let error = manager.costError {
                unavailableRow(error)
            } else {
                loadingRow("Reading local cost…")
            }

            Link("OpenAI pricing", destination: URL(string: "https://developers.openai.com/api/docs/models/gpt-5.6-sol")!)
                .font(.caption2)
        }
    }

    private var forecastCard: some View {
        CodexCard(
            title: "Reset forecast",
            subtitle: "Third-party signal",
            isRefreshing: manager.isForecastRefreshing,
            action: { manager.refreshNow() }
        ) {
            if let forecast = manager.forecast {
                Text("\(Int(forecast.score.rounded()))%")
                    .font(.title2.weight(.semibold).monospacedDigit())
                Text("in the next \(forecast.horizonHours) hours")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let label = forecast.verdictLabel {
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(forecast.resetAnnounced ? .green : .secondary)
                        .lineLimit(1)
                }

                if let fetchedAt = forecast.fetchedAt {
                    Text("Source updated \(CodexTimeFormatter.relative(fetchedAt, from: presentationDate))")
                        .font(.caption2)
                        .foregroundStyle(manager.forecastError == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                if forecast.sourceStale {
                    Text("Source is stale")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else if let error = manager.forecastError {
                unavailableRow(error)
            } else {
                loadingRow("Loading forecast…")
            }

            Link("Will Codex Reset?", destination: CodexResetForecast.sourceURL)
                .font(.caption2)
            Text("Third-party data, not a Notch estimate.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unofficial reset forecast")
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
        }
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

    private func officialFreshness(_ snapshot: CodexUsageSnapshot) -> String {
        let prefix = manager.usageError == nil ? "Updated" : "Stale · updated"
        return "\(prefix) \(CodexTimeFormatter.relative(snapshot.fetchedAt, from: presentationDate))"
    }

    private func visibleQuotaLimits(_ limits: [CodexUsageLimit]) -> [CodexUsageLimit] {
        var result: [CodexUsageLimit] = []
        let sorted = limits.sorted { ($0.windowDurationMinutes ?? Int.max) < ($1.windowDurationMinutes ?? Int.max) }

        func limit(for durationMinutes: Int) -> CodexUsageLimit? {
            let candidates = sorted.filter { $0.windowDurationMinutes == durationMinutes }
            guard durationMinutes == CodexQuotaWindowPreference.weekly.durationMinutes else {
                return candidates.first
            }
            return candidates.first(where: {
                !$0.name.localizedCaseInsensitiveContains("spark")
            }) ?? candidates.first
        }

        if let preferred = limit(for: preferredWindow.durationMinutes) {
            result.append(preferred)
        }
        let secondaryWindow: CodexQuotaWindowPreference = preferredWindow == .fiveHour ? .weekly : .fiveHour
        if let secondary = limit(for: secondaryWindow.durationMinutes), !result.contains(where: { $0.id == secondary.id }) {
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
    let isRefreshing: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String,
        isRefreshing: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isRefreshing = isRefreshing
        self.action = action
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

                Button(action: action) {
                    CodexRefreshIndicator(isRefreshing: isRefreshing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh \(title)")
            }

            content()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum CodexIdleUsageLayout {
    static let sideWidth: CGFloat = 32
    static let sidePadding: CGFloat = 4
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
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: CodexIdleUsageLayout.sideWidth, alignment: .trailing)
                    .padding(.horizontal, CodexIdleUsageLayout.sidePadding)

                Color.black
                    .frame(width: CodexIdleUsageLayout.compactCenterWidth(for: notchWidth))

                Text(balanceLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(balanceColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: CodexIdleUsageLayout.sideWidth, alignment: .leading)
                    .padding(.horizontal, CodexIdleUsageLayout.sidePadding)
            }
            .frame(height: height)
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
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(balanceColor)
            .monospacedDigit()
            .lineLimit(1)
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
        let preferred = sorted.filter { $0.windowDurationMinutes == preferredWindow.durationMinutes }
        if preferredWindow == .weekly {
            return preferred.first(where: {
                !$0.name.localizedCaseInsensitiveContains("spark")
            }) ?? preferred.first ?? sorted.first
        }
        return preferred.first ?? sorted.first
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

private struct CodexRefreshIndicator: View {
    let isRefreshing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            .font(.body.weight(.medium))
            .rotationEffect(.degrees(isRefreshing && !reduceMotion ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: isRefreshing
            )
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
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
        ZStack {
            ProgressView(value: displayedPercent, total: 100)
                .progressViewStyle(.linear)
                .tint(.accentColor)
            if let expectedPercent {
                GeometryReader { geometry in
                    Capsule()
                        .fill(.primary.opacity(0.78))
                        .frame(width: 2, height: 8)
                        .position(
                            x: markerPosition(width: geometry.size.width, percent: expectedPercent),
                            y: geometry.size.height / 2
                        )
                }
                .accessibilityHidden(true)
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
