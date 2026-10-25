# Changelog

All notable changes are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-25

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
  accepts the request. Authorization and scheduling failures are shown in a
  dedicated menu row, and the prior baseline is retained for retry.
- Status and forecast rows are no longer grayed out; only genuinely unavailable
  controls are disabled. Error text uses a color with WCAG AA contrast in light
  and dark appearances.
- Left-clicking the status icon opens an information window (7-day usage,
  windows, baseline, forecast, errors) that updates while open. Right-clicking
  (or control-clicking) opens the actions menu.
- The menu-bar icon is now the packaged `AppIcon.icns` in color instead of an SF
  Symbol; the symbol remains only as a fallback.
- The gap between the icon and the usage label is a compact 4 pt.

- Makes the 7-day label toggle prominent directly below the menu heading and
  changes its title to **Hide 7d Label** or **Show 7d Label** so the current
  action is unambiguous. The native check mark, icon-only mode, and persisted
  `codexShowUsageInMenuBar` preference are unchanged.

## [0.1.0] - 2026-10-24

- Initial public release.
- Reads Codex rate limits through the local `codex app-server`.
- Sends at most one local notification when a prior 7-day window appears to be
  restored early, and only when Codex reports ordinary usage is allowed.
- Shows primary and secondary usage windows, the persisted baseline, and
  codexreset.org forecasts in a native menu.
- Adds Refresh, Copy Status Summary, Open codexreset.org, and Quit actions with
  keyboard shortcuts and VoiceOver-friendly labels and tooltips.
- Adds the native checked **Show Usage in Menu Bar** toggle. The usage text is
  visible by default, the setting persists in `UserDefaults` as
  `codexShowUsageInMenuBar`, and the menu-bar icon always remains visible.
- Adds a universal (Apple Silicon and Intel) ad-hoc-signed build, fixture-based
  tests, macOS CI, and a tag-driven release workflow.
- Publishes a direct-download macOS DMG containing `CodexResetTray.app` and an
  `Applications` shortcut, with a SHA-256 checksum. The packaging script
  validates the image through a read-only attach before release.
