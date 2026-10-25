import Combine
import Foundation

@MainActor
final class ResetStore: ObservableObject {
    @Published private(set) var snapshot: CodexRateLimitSnapshot?
    @Published private(set) var codexError: String?
    @Published private(set) var lastCodexCheck: Date?
    @Published private(set) var isPollingCodex = false

    @Published private(set) var baseline: WeeklyUsageBaseline?
    @Published private(set) var lastNotificationScheduledAt: Date?

    @Published private(set) var forecast: ResetSnapshot?
    @Published private(set) var forecastError: String?
    @Published private(set) var lastForecastCheck: Date?
    @Published private(set) var lastForecastSuccess: Date?
    @Published private(set) var isFetchingForecast = false

    @Published private(set) var notificationStatus: String?
    @Published private(set) var notificationStatusIsError = false
    @Published private(set) var notificationAuthorization: NotificationAuthorization?
    @Published private(set) var showsUsageInMenuBar: Bool

    private static let pollInterval: UInt64 = 5 * 60 * 1_000_000_000
    private static let menuForecastDebounce: TimeInterval = 5

    private let baselineStore: BaselineStore
    private let visibilityStore: MenuBarVisibilityStore
    private let notifications: any NotificationScheduling
    private let fetchRateLimits: @Sendable () async throws -> CodexRateLimitSnapshot
    private var pollingTask: Task<Void, Never>?
    private var hasEstablishedSessionBaseline = false
    private var hasAttemptedNotificationScheduling = false
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
            lastNotificationScheduledAt: lastNotificationScheduledAt,
            notificationStatus: notificationStatus,
            notificationStatusIsError: notificationStatusIsError,
            forecast: forecast,
            forecastError: forecastError,
            isFetchingForecast: isFetchingForecast,
            lastCodexCheck: lastCodexCheck,
            lastForecastCheck: lastForecastCheck,
            lastForecastSuccess: lastForecastSuccess,
            showsUsageInMenuBar: showsUsageInMenuBar,
            notificationPermission: TrayNotificationPermission(notificationAuthorization)
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

        hasAttemptedNotificationScheduling = true
        let delivery = await notifications.schedule(alert)
        switch delivery {
        case .scheduled:
            // Commit both the new reading and the per-deadline marker only now.
            let committed = observedBaseline.markingAlerted(resetsAt: alert.resetsAt)
            baseline = committed
            baselineStore.save(committed)
            lastNotificationScheduledAt = now
            setNotificationStatus(
                "Reset notification scheduled. Visual delivery depends on macOS settings.",
                isError: false
            )
        case .notAuthorized(let authorization):
            // Keep the previous baseline so the next poll can retry with the same
            // evidence instead of silently losing the restoration.
            setNotificationStatus(
                "Reset notification not scheduled: \(authorization.explanation)",
                isError: true
            )
        case .failed(let message):
            setNotificationStatus(
                "Could not schedule the reset notification: \(message)",
                isError: true
            )
        }
    }

    /// Re-reads macOS authorization without prompting. The menu controller
    /// calls this when the menu opens or the app regains focus so the native
    /// check mark follows changes made in System Settings.
    func refreshNotificationAuthorization() async -> NotificationAuthorization {
        let status = await notifications.authorizationStatus()
        applyNotificationAuthorization(status)
        return status
    }

    /// Requests permission only when the menu action explicitly asks. The
    /// scheduler itself guards against re-prompting a decided app.
    func requestNotificationAuthorization() async -> NotificationAuthorization {
        let status = await notifications.requestAuthorization()
        applyNotificationAuthorization(status)
        return status
    }

    private func applyNotificationAuthorization(_ status: NotificationAuthorization) {
        notificationAuthorization = status
        // A scheduling result is more specific than a read-only authorization
        // result; never let a late permission response hide a failure or success.
        guard !hasAttemptedNotificationScheduling else { return }
        switch status {
        case .authorized, .provisional, .ephemeral:
            setNotificationStatus("Notifications are allowed.", isError: false)
        case .denied:
            setNotificationStatus(
                "Notifications are denied in System Settings; reset alerts cannot be scheduled.",
                isError: true
            )
        case .notDetermined:
            setNotificationStatus(
                "Notification permission has not been decided; reset alerts may not appear.",
                isError: true
            )
        case .error(let message):
            setNotificationStatus(
                "Notification permission check failed: \(message)",
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

private extension TrayNotificationPermission {
    init(_ authorization: NotificationAuthorization?) {
        switch authorization {
        case nil, .some(.error(_)):
            self = .unknown
        case .some(.notDetermined):
            self = .notDetermined
        case .some(.denied):
            self = .denied
        case .some(.authorized), .some(.provisional), .some(.ephemeral):
            self = .allowed
        }
    }
}
