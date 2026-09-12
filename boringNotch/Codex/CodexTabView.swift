import Defaults
import SwiftUI

struct CodexTabView: View {
    @ObservedObject private var manager = CodexUsageManager.shared
    @State private var presentationDate = Date()
    @Default(.codexUsageMetric) private var usageMetric

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                header
                officialQuotaSection
                apiCostSection
                forecastSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex")
                    .font(.title3.weight(.semibold))
                Text("Local quota and usage")
                    .font(.caption)
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
            .help("Refresh Codex usage")
            .accessibilityLabel("Refresh Codex usage")
        }
    }

    private var officialQuotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(
                title: "Codex quota",
                subtitle: "From the local Codex app",
                isRefreshing: manager.isOfficialRefreshing,
                action: { manager.refreshNow() }
            )

            if let snapshot = manager.snapshot {
                Text(officialFreshness(snapshot))
                    .font(.caption2)
                    .foregroundStyle(manager.usageError == nil ? Color.secondary : Color.orange)
                ForEach(visibleQuotaLimits(snapshot.limits)) { limit in
                    quotaWindow(limit, observedAt: snapshot.fetchedAt)
                }
                if manager.usageError != nil {
                    Label("Refresh failed · showing the last quota", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let error = manager.usageError {
                unavailableRow(error)
            } else {
                loadingRow("Reading local quota…")
            }
        }
    }

    private func quotaWindow(_ limit: CodexUsageLimit, observedAt: Date) -> some View {
        let pace = CodexQuotaPaceCalculator.pace(
            for: limit,
            observedAt: observedAt,
            now: presentationDate
        )
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shortQuotaName(limit.name))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(limit.displayedPercent(for: usageMetric).rounded()))% \(usageMetric.accessibilityLabel)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }

            CodexQuotaMeter(
                displayedPercent: limit.displayedPercent(for: usageMetric),
                expectedPercent: pace?.expectedDisplayedPercent(for: usageMetric)
            )

            if let pace {
                Text(paceSummary(pace, relativeTo: presentationDate))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(paceColor(pace.status))
                    .lineLimit(1)
            }
            if let resetsAt = limit.resetsAt {
                Text("Resets in \(CodexTimeFormatter.resetDate(resetsAt, from: presentationDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(limitAccessibilityLabel(limit, pace: pace))
    }

    private var apiCostSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeading(
                title: "API-price equivalent",
                subtitle: "This Mac · last 30 days",
                isRefreshing: manager.isCostRefreshing,
                action: { manager.refreshNow() }
            )

            if let estimate = manager.costEstimate {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(estimate.measurement.amount.formatted(.currency(code: estimate.measurement.currency)))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Reviewed OpenAI rates")
                        if let pricingAsOf = estimate.measurement.pricingAsOf {
                            Text("as of \(pricingAsOf.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                }

                Text("Updated \(CodexTimeFormatter.relative(estimate.refreshedAt, from: presentationDate))")
                    .font(.caption2)
                    .foregroundStyle(manager.costError == nil ? Color.secondary : Color.orange)

                if estimate.measurement.partial || estimate.unpricedTokenCount > 0 {
                    Label("Partial estimate · some local usage was excluded", systemImage: "circle.dashed")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let error = manager.costError {
                    Label("Refresh failed · showing the last estimate", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let error = manager.costError {
                unavailableRow(error)
            } else {
                loadingRow("Reading local token counters…")
            }

            Text("Estimate only; not your subscription charge or an actual bill. Tool fees and unsupported models are excluded.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("OpenAI pricing", destination: URL(string: "https://developers.openai.com/api/docs/models/gpt-5.6-sol")!)
                .font(.caption2)
        }
    }

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unofficial reset forecast")
                        .font(.subheadline.weight(.semibold))
                    Link("Will Codex Reset?", destination: CodexResetForecast.sourceURL)
                        .font(.caption)
                }
                Spacer(minLength: 0)
                if let forecast = manager.forecast {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(forecast.score.rounded()))% in the next \(forecast.horizonHours) hours")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                        if let label = forecast.verdictLabel {
                            Text(label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(forecast.resetAnnounced ? .green : .secondary)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                }
                Button {
                    manager.refreshNow()
                } label: {
                    CodexRefreshIndicator(isRefreshing: manager.isForecastRefreshing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh reset forecast")
                .accessibilityLabel("Refresh reset forecast")
            }

            if let forecast = manager.forecast {
                HStack(spacing: 4) {
                    if let fetchedAt = forecast.fetchedAt {
                        Text("Source updated \(CodexTimeFormatter.relative(fetchedAt, from: presentationDate))")
                    }
                    if let checkedAt = manager.lastForecastRefresh {
                        Text("· checked \(CodexTimeFormatter.relative(checkedAt, from: presentationDate))")
                    }
                    if forecast.sourceStale {
                        Text("· stale source")
                    }
                }
                .font(.caption2)
                .foregroundStyle(manager.forecastError == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
            } else if let error = manager.forecastError {
                unavailableRow(error)
            } else {
                loadingRow("Loading third-party forecast…")
            }

            Text("Third-party data shown as provided. It is not Boring Notch data or a Boring Notch estimate, and Boring Notch does not warrant it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unofficial reset forecast")
    }

    private func sectionHeading(
        title: String,
        subtitle: String,
        isRefreshing: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: action) {
                CodexRefreshIndicator(isRefreshing: isRefreshing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Refresh \(title)")
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func unavailableRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption)
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
        if let fiveHour = sorted.first(where: { $0.windowDurationMinutes == 300 }) {
            result.append(fiveHour)
        }
        if let weekly = sorted.first(where: {
            $0.windowDurationMinutes == 10_080
                && !$0.name.localizedCaseInsensitiveContains("spark")
        }) ?? sorted.first(where: { $0.windowDurationMinutes == 10_080 }) {
            result.append(weekly)
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

    private func paceSummary(_ pace: CodexQuotaPace, relativeTo referenceDate: Date) -> String {
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

    private func paceColor(_ status: CodexQuotaPaceStatus) -> Color {
        switch status {
        case .reserve, .onPace:
            return .secondary
        case .deficit:
            return .orange
        }
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

private struct CodexRefreshIndicator: View {
    let isRefreshing: Bool

    var body: some View {
        Group {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.medium))
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
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
