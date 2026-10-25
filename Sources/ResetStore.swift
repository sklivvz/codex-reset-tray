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
    @Published private(set) var lastForecastSuccess: Date?
    @Published private(set) var isFetchingForecast = false

    @Published private(set) var notificationStatus: String?
    @Published private(set) var notificationStatusIsError = false
    @Published private(set) var showsUsageInMenuBar: Bool

    private static let pollInterval: UInt64 = 5 * 60 * 1_000_000_000
    private static let menuForecastDebounce: TimeInterval = 5

    private let baselineStore: BaselineStore
    private let visibilityStore: MenuBarVisibilityStore
    private let notifications: any NotificationScheduling
    private let fetchRateLimits: @Sendable () async throws -> CodexRateLimitSnapshot
    private var pollingTask: Task<Void, Never>?
    private var hasRequestedNotificationAuthorization = false
    private var hasEstablishedSessionBaseline = false
    private var hasAttemptedAlertDelivery = false
    private var lastMenuForecastFetch: Date?
    private let fetchForecast: () async throws -> ResetSnapshot

    init(
        defaults: UserDefaults = .standard,
        notifications: any NotificationScheduling = SystemNotificationScheduler(),
        fetchForecast: @escaping () async throws -> ResetSnapshot = ResetPage.fetch,
        fetchRateLimits: @escaping @Sendable () async throws -> CodexRateLimitSnapshot = {
            try await CodexAppServerClient.fetchRateLimits()
        }
    ) {
        let store = BaselineStore(defaults: defaults)
        let visibility = MenuBarVisibilityStore(defaults: defaults)
        baselineStore = store
        visibilityStore = visibility
        self.notifications = notifications
        self.fetchForecast = fetchForecast
        self.fetchRateLimits = fetchRateLimits
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
            notificationStatusIsError: notificationStatusIsError,
            forecast: forecast,
            forecastError: forecastError,
            isFetchingForecast: isFetchingForecast,
            lastCodexCheck: lastCodexCheck,
            lastForecastCheck: lastForecastCheck,
            lastForecastSuccess: lastForecastSuccess,
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
        if forecastError == nil, let last = lastMenuForecastFetch,
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

        let result: Result<CodexRateLimitSnapshot, Error>
        do {
            result = .success(try await fetchRateLimits())
        } catch {
            result = .failure(error)
        }

        // The permission prompt starts only after the first usage fetch has begun
        // (and completed). It does not block evaluation of the reading.
        requestNotificationAuthorizationIfNeeded()

        let now = Date()
        let outcome = CodexPoller.apply(result, baseline: baseline, now: now)
        if let snapshot = outcome.snapshot {
            self.snapshot = snapshot
        }
        codexError = outcome.errorMessage
        lastCodexCheck = now

        // A failed, unreadable, or windowless response preserves the existing
        // baseline and can never alert.
        guard outcome.observedWeekly != nil, let observedBaseline = outcome.baseline else {
            return
        }

        // The first successful reading of a launch only adopts current state. A
        // persisted baseline may describe a reset from while the app was closed.
        guard hasEstablishedSessionBaseline else {
            hasEstablishedSessionBaseline = true
            baseline = observedBaseline
            baselineStore.save(observedBaseline)
            return
        }

        guard let alert = outcome.alert else {
            baseline = observedBaseline
            baselineStore.save(observedBaseline)
            return
        }

        hasAttemptedAlertDelivery = true
        let delivery = await notifications.schedule(alert)
        switch delivery {
        case .delivered:
            // Commit both the new reading and the per-deadline marker only now.
            let committed = observedBaseline.markingAlerted(resetsAt: alert.resetsAt)
            baseline = committed
            baselineStore.save(committed)
            lastAlertAt = now
            setNotificationStatus(
                "Early-restoration notification scheduled from Codex usage.",
                isError: false
            )
        case .notAuthorized(let authorization):
            // Keep the previous baseline so the next poll can retry with the same
            // evidence instead of silently losing the restoration.
            setNotificationStatus(
                "Early-restoration notification not sent: \(authorization.explanation)",
                isError: true
            )
        case .failed(let message):
            setNotificationStatus(
                "Could not schedule the early-restoration notification: \(message)",
                isError: true
            )
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !hasRequestedNotificationAuthorization else { return }
        hasRequestedNotificationAuthorization = true
        // This starts only after the first usage fetch has begun. It deliberately
        // does not block polling if the system prompt is left unanswered.
        Task { [weak self] in
            guard let self else { return }
            let status = await self.notifications.requestAuthorization()
            self.applyAuthorizationStatus(status)
        }
    }

    private func applyAuthorizationStatus(_ status: NotificationAuthorization) {
        // A delivery result is more specific than a background authorization
        // result; never let a late permission response hide a failure or success.
        guard !hasAttemptedAlertDelivery else { return }
        switch status {
        case .authorized, .provisional, .ephemeral:
            setNotificationStatus("Notifications are allowed.", isError: false)
        case .denied:
            setNotificationStatus(
                "Notifications are denied in System Settings; early-restoration alerts cannot appear.",
                isError: true
            )
        case .notDetermined:
            setNotificationStatus(
                "Notification permission has not been decided; early-restoration alerts may not appear.",
                isError: true
            )
        case .error(let message):
            setNotificationStatus(
                "Could not request notification permission: \(message)",
                isError: true
            )
        }
    }

    private func setNotificationStatus(_ text: String, isError: Bool) {
        notificationStatus = text
        notificationStatusIsError = isError
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
            forecast = try await fetchForecast()
            forecastError = nil
            let now = Date()
            lastForecastCheck = now
            lastForecastSuccess = now
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
