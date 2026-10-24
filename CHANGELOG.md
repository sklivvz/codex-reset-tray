# Changelog

All notable changes are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
