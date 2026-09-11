import Combine
import Foundation

@MainActor
final class CodexUsageManager: ObservableObject {
    static let shared = CodexUsageManager()

    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var costEstimate: CodexCostEstimate?
    @Published private(set) var forecast: CodexResetForecast?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isOfficialRefreshing = false
    @Published private(set) var isCostRefreshing = false
    @Published private(set) var isForecastRefreshing = false
    @Published private(set) var usageError: String?
    @Published private(set) var costError: String?
    @Published private(set) var forecastError: String?
    @Published private(set) var lastOfficialRefresh: Date?
    @Published private(set) var lastCostRefresh: Date?
    @Published private(set) var lastForecastRefresh: Date?

    private let usageService: any CodexUsageFetching
    private let costService: any CodexLocalCostEstimating
    private let forecastService: any CodexResetForecastFetching
    private var periodicTask: Task<Void, Never>?
    private var officialTask: Task<Void, Never>?
    private var costTask: Task<Void, Never>?
    private var forecastTask: Task<Void, Never>?

    init(
        usageService: any CodexUsageFetching = CodexUsageService(),
        costService: any CodexLocalCostEstimating = CodexLocalCostService(),
        forecastService: any CodexResetForecastFetching = CodexResetForecastService()
    ) {
        self.usageService = usageService
        self.costService = costService
        self.forecastService = forecastService
    }

    func start() {
        guard periodicTask == nil else { return }
        refreshOfficial(force: true)
        refreshForecast(force: true)
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshIfNeeded(includeCost: false)
            }
        }
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        officialTask?.cancel()
        costTask?.cancel()
        forecastTask?.cancel()
        officialTask = nil
        costTask = nil
        forecastTask = nil
        isRefreshing = false
        isOfficialRefreshing = false
        isCostRefreshing = false
        isForecastRefreshing = false
    }

    func refreshNow() {
        refreshOfficial(force: true)
        refreshCost(force: true)
        refreshForecast(force: true)
    }

    func refreshIfNeeded(now: Date = Date(), includeCost: Bool = false) {
        refreshOfficial(
            force: isStale(lastOfficialRefresh, interval: 5 * 60, now: now))
        if includeCost {
            refreshCost(
                force: isStale(lastCostRefresh, interval: 5 * 60, now: now))
        }
        refreshForecast(
            force: isStale(lastForecastRefresh, interval: 15 * 60, now: now))
    }

    private func refreshOfficial(force: Bool) {
        guard force, officialTask == nil else { return }
        isOfficialRefreshing = true
        updateRefreshingState()
        let service = usageService
        officialTask = Task { @MainActor [weak self] in
            do {
                let next = try await service.fetchUsage()
                guard let self, !Task.isCancelled else { return }
                self.snapshot = next
                self.usageError = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.usageError = error.localizedDescription
            }
            guard let self else { return }
            self.lastOfficialRefresh = Date()
            self.isOfficialRefreshing = false
            self.officialTask = nil
            self.updateRefreshingState()
        }
    }

    private func refreshCost(force: Bool) {
        guard force, costTask == nil else { return }
        isCostRefreshing = true
        updateRefreshingState()
        let service = costService
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let interval = DateInterval(start: start, end: now)
        costTask = Task { @MainActor [weak self] in
            do {
                let next = try await service.estimate(interval: interval)
                guard let self, !Task.isCancelled else { return }
                self.costEstimate = next
                self.costError = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.costError = error.localizedDescription
            }
            guard let self else { return }
            self.lastCostRefresh = Date()
            self.isCostRefreshing = false
            self.costTask = nil
            self.updateRefreshingState()
        }
    }

    private func refreshForecast(force: Bool) {
        guard force, forecastTask == nil else { return }
        isForecastRefreshing = true
        updateRefreshingState()
        let service = forecastService
        forecastTask = Task { @MainActor [weak self] in
            do {
                let next = try await service.fetchForecast()
                guard let self, !Task.isCancelled else { return }
                self.forecast = next
                self.forecastError = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.forecastError = error.localizedDescription
            }
            guard let self else { return }
            self.lastForecastRefresh = Date()
            self.isForecastRefreshing = false
            self.forecastTask = nil
            self.updateRefreshingState()
        }
    }

    private func updateRefreshingState() {
        isRefreshing = isOfficialRefreshing || isCostRefreshing || isForecastRefreshing
    }

    private func isStale(_ date: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= interval
    }
}
