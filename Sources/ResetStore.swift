import Combine
import Foundation

@MainActor
final class ResetStore: ObservableObject {
    @Published private(set) var snapshot: CodexRateLimitSnapshot?
    @Published private(set) var codexError: String?
    @Published private(set) var lastCodexCheck: Date?
    @Published private(set) var isPollingCodex = false

    @Published private(set) var baseline: WeeklyUsageBaseline?
    @Published private(set) var lastAlertAt: Date?

    @Published private(set) var forecast: ResetSnapshot?
    @Published private(set) var forecastError: String?
    @Published private(set) var lastForecastCheck: Date?
    @Published private(set) var isFetchingForecast = false

    @Published private(set) var notificationStatus: String?
    @Published private(set) var showsUsageInMenuBar: Bool

    private static let pollInterval: UInt64 = 5 * 60 * 1_000_000_000
    private static let menuForecastDebounce: TimeInterval = 5

    private let baselineStore: BaselineStore
    private let visibilityStore: MenuBarVisibilityStore
    private var pollingTask: Task<Void, Never>?
    private var hasStartedFirstFetch = false
    private var lastMenuForecastFetch: Date?

    init(defaults: UserDefaults = .standard) {
        let store = BaselineStore(defaults: defaults)
        let visibility = MenuBarVisibilityStore(defaults: defaults)
        baselineStore = store
        visibilityStore = visibility
        baseline = store.load()
        showsUsageInMenuBar = visibility.load()
    }

    var menuBarTitle: String {
        guard showsUsageInMenuBar else { return "" }
        let base: String
        if let weekly = snapshot?.weeklyWindow {
            base = "7d \(Int(weekly.usedPercent.rounded()))%"
        } else if isPollingCodex {
            base = "Codex…"
        } else {
            base = "Codex"
        }
        return codexError == nil ? base : "\(base) !"
    }

    var menuBarSystemImage: String {
        codexError == nil ? "chart.bar.fill" : "exclamationmark.triangle.fill"
    }

    var menuState: TrayMenuState {
        TrayMenuState(
            snapshot: snapshot,
            codexError: codexError,
            isPollingCodex: isPollingCodex,
            baseline: baseline,
            lastAlertAt: lastAlertAt,
            notificationStatus: notificationStatus,
            forecast: forecast,
            forecastError: forecastError,
            isFetchingForecast: isFetchingForecast,
            lastCodexCheck: lastCodexCheck,
            lastForecastCheck: lastForecastCheck,
            showsUsageInMenuBar: showsUsageInMenuBar
        )
    }

    /// The menu-bar icon is independent of this setting and is never hidden.
    func setShowsUsageInMenuBar(_ visible: Bool) {
        guard visible != showsUsageInMenuBar else { return }
        showsUsageInMenuBar = visible
        visibilityStore.save(visible)
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollCodex()
                do {
                    try await Task.sleep(nanoseconds: Self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Called when the menu content appears. Forecasts are informational and are
    /// fetched only here and from the explicit Refresh button.
    func menuDidOpen() {
        let now = Date()
        if let last = lastMenuForecastFetch,
           now.timeIntervalSince(last) < Self.menuForecastDebounce {
            return
        }
        lastMenuForecastFetch = now
        Task { await refreshForecast() }
    }

    func pollCodex() async {
        guard !isPollingCodex else { return }
        isPollingCodex = true
        defer { isPollingCodex = false }

        if !hasStartedFirstFetch {
            hasStartedFirstFetch = true
            // The permission prompt starts only once the first usage fetch has begun.
            Task { [weak self] in
                let granted = await NotificationScheduler.requestAuthorization()
                self?.notificationStatus = granted
                    ? "Notifications are allowed."
                    : "Notifications are not allowed; early-restoration alerts cannot appear."
            }
        }

        let result: Result<CodexRateLimitSnapshot, Error>
        do {
            result = .success(try await CodexAppServerClient.fetchRateLimits())
        } catch {
            result = .failure(error)
        }

        let now = Date()
        let outcome = CodexPoller.apply(result, baseline: baseline, now: now)
        if let snapshot = outcome.snapshot {
            self.snapshot = snapshot
        }
        baseline = outcome.baseline
        baselineStore.save(outcome.baseline)
        codexError = outcome.errorMessage
        lastCodexCheck = now

        if let alert = outcome.alert {
            lastAlertAt = now
            let delivered = await NotificationScheduler.send(alert)
            if delivered {
                notificationStatus = "Early-restoration alert sent from Codex usage."
            } else {
                notificationStatus = "Could not schedule the early-restoration alert."
            }
        }
    }

    func refreshAll() async {
        await pollCodex()
        await refreshForecast()
    }

    func refreshForecast() async {
        guard !isFetchingForecast else { return }
        isFetchingForecast = true
        defer { isFetchingForecast = false }

        do {
            forecast = try await ResetPage.fetch()
            forecastError = nil
            lastForecastCheck = Date()
        } catch {
            forecastError = error.localizedDescription
            lastForecastCheck = Date()
        }
    }
}

/// Persists the user's menu-bar usage-text preference. A missing key means the
/// default, visible state, including for existing installs upgrading the app.
struct MenuBarVisibilityStore {
    static let key = "codexShowUsageInMenuBar"
    let defaults: UserDefaults

    func load() -> Bool {
        guard defaults.object(forKey: Self.key) != nil else { return true }
        return defaults.bool(forKey: Self.key)
    }

    func save(_ visible: Bool) {
        defaults.set(visible, forKey: Self.key)
    }
}
