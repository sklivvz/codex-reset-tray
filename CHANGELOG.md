# Changelog

All notable changes are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Simplify the left-click data popover to the usage headline/meter and two large
  side-by-side 24h/48h forecast probabilities. Remove the Codex usage section,
  latest confirmed reset row, six-line footer, version/build text, and all
  notification-denial prose. Loading, stale, and unavailable forecasts keep the
  two-column layout and use normal label or readable error text, never disabled
  gray.
- Add a checked **Enable Notifications** item to the native right-click menu. It
  is checked only when macOS reports a status that allows delivery; undetermined
  clicks request authorization, while denied and already-allowed clicks open
  System Settings > Notifications. Authorization refreshes when the menu opens
  or the app regains focus. Notification permission is no longer requested after
  a Codex fetch or while scheduling a reset; only the menu action can prompt.
- Add **About Codex Reset Tray**, which opens AppKit's standard About panel with
  the bundle icon, version, and build through an injectable presenter.
- Keep Copy Status Summary as the full diagnostic report (usage windows,
  baseline, reset, notification/scheduling, forecast, and check times) even
  though the popover is compact.
- Update the offscreen and opt-in live AppKit tests for exact popover content and
  absence, large forecast typography and side-by-side layout, notification
  item states and click routing, menu/focus authorization refresh, no automatic
  prompting, and the About action/panel configuration.

- Split the status item into exactly two surfaces. Left click opens one compact,
  anchored, transient data popover with the usage headline/meter and two large
  forecast figures; right click (or control-click) dismisses that popover and
  opens one native actions menu containing only the 7d label toggle, Enable
  Notifications, Refresh, Copy Status Summary, Open codexreset.org, Support this
  project, About Codex Reset Tray, and Quit. The menu has no informational rows
  or heading, and gray is reserved for genuinely disabled actions.
- Keep the menu and popover models independent (`TrayMenuModel` versus
  `TrayInfoModel`), keep the full diagnostic report in Copy Status Summary, and
  add deterministic tests that fail if status content leaks back into the menu.
- Run the opt-in `--live-status-item` harness on GitHub-hosted macOS CI after
  the normal build and test steps, enforcing its exit status and watchdog.

- Parse the current codexreset.org layout when `quota-restoration-status` is
  absent, while reporting timeline confirmations as global-only and preserving
  strict timestamp and forecast-probability validation.

- Detect and notify for normal scheduled 7-day window rollovers as well as early
  resets. An advancing `resetsAt` is sufficient evidence even when usage has
  already climbed in the new window; the old behavior suppressed every reset at
  or near the scheduled deadline. A confirmed new window also alerts when the
  prior baseline was 0%; prior usage now gates only same-deadline usage-drop
  inference.
- Classify the notification as a scheduled or early reset and avoid duplicate
  notifications with the persisted per-deadline marker. Startup still adopts the
  first reading without alerting, and time passing without a new deadline or a
  usage drop is not treated as a reset.
- Install a `UNUserNotificationCenterDelegate` that presents banner, list, and
  sound while the accessory app is active, since nil-trigger notifications can be
  suppressed in the foreground.
- Request notification permission only from the explicit **Enable
  Notifications** menu action. Scheduling a reset checks authorization
  read-only, and the authorization check also runs when the menu opens or the
  app regains focus so the check mark follows System Settings.
- Preserve the actual `NSError` domain and code in a sanitized notification
  diagnostic (path-like domain characters are replaced), and distinguish a
  scheduled notification request from confirmed visual delivery in Copy Status
  Summary.
- Add deterministic tests for scheduled and early resets, both weekly slots,
  startup suppression, marker persistence, foreground delegate registration,
  scheduling, authorization denial/errors, and sanitized error diagnostics.

- Adds a Support this project action and repository funding link to the active
  PayPal.Me/sklivvz recipient page.


- Detect early 7-day quota restoration from a materially lower post-reset usage
  reading, not only from usage at or below 1%. A new reset deadline can also
  provide the restoration signal when usage has already climbed again.
- Treat usage drops as material at 3 points and half of prior usage, with a
  separate small-usage path when the quota clears to 1% or less. The old
  five-point/near-zero rule could miss real resets.
- Report `ordinaryUsageAllowed` in the alert but do not require it as proof that
  the quota was restored.
- Never alert on the first successful reading after launch, even with a
  persisted baseline, so startup historical state is not reported as new.
- Commit the per-window alert marker only after the notification scheduler
  accepts the request. Authorization and scheduling failures remain in Copy
  Status Summary, and the prior baseline is retained for retry.
- Informational status, usage, reset, notification, and forecast rows no longer
  appear in the right-click menu, so native gray can only mean a disabled
  action. The compact left-click popover keeps the usage headline/meter and
  forecast figures; larger diagnostic detail lives in Copy Status Summary.
- Left-clicking the status icon opens one compact, transient data popover
  anchored to the menu-bar item (usage headline/meter and two 24h/48h forecast
  figures) that updates while open. Right-clicking (or control-clicking)
  dismisses it and opens the actions-only native menu.
- The menu-bar icon is now a monochrome template mask derived from the packaged
  `AppIcon.icns` instead of an SF Symbol; the packaged app icon itself remains
  colored, and the SF Symbol is used only as a fallback.
- The popover's usage meter spans the full content width instead of only the
  width of the small usage value/caption stack.
- Copy Status Summary builds an independent full diagnostic report (usage
  windows, baseline, reset, notification/scheduling, forecast, and check times)
  without printing duplicate detail lines.
- The gap between the icon and the usage label is a compact 4 pt.

- Makes the 7-day label toggle the first action in the menu, with no heading
  above it, and keeps its exact title **Show 7d Label** in both states. The
  native check mark is present while the usage text is visible and cleared when
  it is hidden. Icon-only mode and the persisted `codexShowUsageInMenuBar`
  preference are unchanged.

## [0.1.0] - 2026-10-24

- Initial public release.
- Reads Codex rate limits through the local `codex app-server`.
- Sends at most one local notification when a prior 7-day window appears to be
  restored early, and only when Codex reports ordinary usage is allowed.
- Shows primary and secondary usage windows, the persisted baseline, and
  codexreset.org forecasts in a native menu.
- Adds Refresh, Copy Status Summary, Open codexreset.org, and Quit actions with
  keyboard shortcuts and VoiceOver-friendly labels and tooltips.
- Adds the native checked **Show 7d Label** toggle. The usage text is visible by
  default, the setting persists in `UserDefaults` as
  `codexShowUsageInMenuBar`, and the menu-bar icon always remains visible.
- Adds a universal (Apple Silicon and Intel) ad-hoc-signed build, fixture-based
  tests, macOS CI, and a tag-driven release workflow.
- Publishes a direct-download macOS DMG containing `CodexResetTray.app` and an
  `Applications` shortcut, with a SHA-256 checksum. The packaging script
  validates the image through a read-only attach before release.
