# Codex Reset Tray

[![CI](https://github.com/sklivvz/codex-reset-tray/actions/workflows/ci.yml/badge.svg)](https://github.com/sklivvz/codex-reset-tray/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/sklivvz/codex-reset-tray)](https://github.com/sklivvz/codex-reset-tray/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small macOS menu-bar app that watches **your own Codex quota** through the
local `codex app-server` and notifies you when the 7-day usage window appears to
have been restored early. It also shows [codexreset.org](https://codexreset.org/)
forecasts in the menu, but those forecasts are informational and never trigger
notifications.

## Download for macOS

[**Download Codex Reset Tray v0.1.0 — Universal (Apple Silicon + Intel)**](https://github.com/sklivvz/codex-reset-tray/releases/download/v0.1.0/CodexResetTray-v0.1.0-macos-universal.dmg)

- Direct DMG: [`CodexResetTray-v0.1.0-macos-universal.dmg`](https://github.com/sklivvz/codex-reset-tray/releases/download/v0.1.0/CodexResetTray-v0.1.0-macos-universal.dmg)
- SHA-256: [`CodexResetTray-v0.1.0-macos-universal.dmg.sha256`](https://github.com/sklivvz/codex-reset-tray/releases/download/v0.1.0/CodexResetTray-v0.1.0-macos-universal.dmg.sha256)
- All releases: <https://github.com/sklivvz/codex-reset-tray/releases>

The DMG contains `CodexResetTray.app`, an `Applications` shortcut for
drag-to-install, a short README, `LICENSE`, and `NOTICE`.

### Install

1. Open the DMG.
2. Drag **Codex Reset Tray** onto the **Applications** shortcut.
3. Launch it from Applications.

This is an independent, ad-hoc-signed build, not a notarized Developer ID build.
On first launch macOS may require right-click **Open**, or **System Settings >
Privacy & Security > Open Anyway**. The source is public and the bundle
signature/contents are checked by the packaging script; see
[Build, test, and package](#build-test-and-package).

To verify the download:

```sh
shasum -a 256 -c CodexResetTray-v0.1.0-macos-universal.dmg.sha256
```

## Menu-bar usage toggle

The menu-bar item always shows a bar-chart icon. By default it also shows the
current 7-day usage text, for example `7d 89%`.

- **Show Usage in Menu Bar** is a native checked menu item.
- It is checked by default and can be toggled off to leave only the icon.
- The choice persists in `UserDefaults` under the key
  `codexShowUsageInMenuBar` and is restored on the next launch.
- The icon itself is never hidden by this setting, including in error states.

The offscreen AppKit tests exercise both states, the native check mark, the
retained icon, and persistence across store restarts. They do not click the
real menu-bar item or observe the screen.

## Behavior

### Codex usage: source of truth

- Immediately after launch and then every 5 minutes, the app starts a local
  `codex app-server --listen stdio://`, performs the JSON-RPC `initialize`
  handshake, and calls `account/rateLimits/read`. It only reads usage; it does
  not log in, log out, or modify account state.
- Each call has a hard 10-second deadline. A missing binary, launch failure, RPC
  error, timeout, or malformed response is shown in the tray menu and can never
  produce a notification.
- The 7-day window is identified by `windowDurationMins == 10080`, whichever
  slot (`primary` or `secondary`) contains it. This matters because Codex has
  returned the weekly window as `primary` on some accounts. The window's
  `resetsAt` is used as the prior reset deadline.

### Early-restoration notification

The app persists the latest 7-day usage baseline in `UserDefaults` under
`codexWeeklyUsageBaselineV2`: prior used percentage, prior `resetsAt`, capture
time, and an "already alerted" marker for that reset deadline. A notification is
considered only when **all** of these are true:

1. This launch has already established a session baseline. The first successful
   reading after launch only adopts current state and never alerts, even when a
   persisted baseline exists, because that state may describe a reset that
   happened while the app was closed.
2. The prior 7-day usage was greater than 0%.
3. The current time is more than 5 minutes before the **prior** window's
   `resetsAt`. A reset that is due or imminent is treated as scheduled and does
   not alert.
4. No alert has already been scheduled for that prior reset deadline.
5. There is a genuine restoration signal: either the new 7-day `resetsAt` is at
   least 5 minutes later than the prior deadline while current usage is at most
   25%, or current usage is at most 25% and has fallen materially (at least 3
   percentage points and at least half of the prior usage, or cleared to 1% or
   less from at least 2 points). The ceiling is deliberately above 1%: usage can
   be consumed again before the next poll after a reset.

`ordinaryUsageAllowed` is reported in the notification, but it is not required
as evidence that the quota itself was restored. A false or missing value no
longer suppresses a genuine deadline or usage transition.

The alert is scheduled at most once per reset window. The persisted marker is
written only after the notification scheduler accepts the request. If
authorization is denied or scheduling fails, the prior baseline is retained so a
later poll can retry, and the menu shows an error row with the reason. The alert
is not sent on startup historical state, a scheduled timestamp arriving on its
own, after the prior deadline, on a parse or transport failure, or because a
codexreset.org forecast changed. Notification permission is requested only after
the first usage fetch has begun.

The menu shows primary/secondary windows, the persisted baseline and deadline,
notification permission/delivery state, the latest forecast or forecast error,
and any Codex error. `ordinaryUsageAllowed`, the last read time, and alert timing
are available in item tooltips. Refresh, Copy Status Summary, Show Usage in Menu
Bar, Open codexreset.org, and Quit are always in the menu; Quit is always enabled
and last.

### codexreset.org forecast

- Forecasts are fetched only when the menu opens or when Refresh is pressed.
- Refresh also re-polls Codex usage immediately.
- The forecast shows 24-hour and 48-hour probabilities in the menu, with the
  latest reported restoration and forecast summary available there and in its
  tooltip.
- A failed refresh keeps the last forecast visible as stale and shows when it
  was last updated. Opening the menu retries after a failure.
- The site is never consulted for notification decisions.

## Requirements

- macOS 13 or later
- Apple Command Line Tools with Swift (no Xcode project required)
- The `codex` CLI installed and signed in with ChatGPT auth
- A Codex app-server that supports the v2 `account/rateLimits/read` method

The app looks for `codex` in common install locations and on `PATH` (including
Homebrew paths, since Finder-launched apps get a minimal environment). Set
`CODEX_BINARY=/absolute/path/to/codex` to override discovery.

## Build, test, and package

```sh
./build.sh
./test.sh
./scripts/package-release.sh
```

- `build.sh` compiles the AppKit app and creates an ad-hoc-signed bundle at
  `build/CodexResetTray.app`. Set `BUILD_ARCHS="arm64 x86_64"` for a universal
  binary; `package-release.sh` does this by default. `build.sh` does not install
  or launch the app.
- `test.sh` runs the Codex JSON/transition tests on fixtures, the pure tray menu
  model tests, an offscreen AppKit integration test, the parser smoke test on
  the checked-in fixture, and the bundle/icon/signature checks. Run
  `./build.sh` before `./test.sh` because the bundle test inspects the built app.
- `scripts/package-release.sh` builds the universal app, creates
  `dist/CodexResetTray-v<version>-macos-universal.dmg` containing the app,
  `Applications` shortcut, README, `LICENSE`, and `NOTICE`, writes a
  `.sha256` file, and validates the DMG. Validation verifies the image, attaches
  it **read-only**, checks the bundle identifier/version/icon, verifies the
  app's code signature, confirms both `arm64` and `x86_64`, rejects writes to the
  mounted image, and detaches it.

`Tests/TrayMenuRuntimeTests.swift` compiles the production `TrayMenuController`
with an injected menu source, an unmounted status-button host, a fake URL
opener, and a fake termination handler. It exercises real `NSMenu` and
`NSMenuItem` instances and checks:

- the menu is nonempty before and on the first open;
- the status button has a renderable template image with nontransparent pixels;
- status, usage-window, baseline, forecast, forecast-detail, and error rows;
- the checked **Show Usage in Menu Bar** toggle in both states, with the icon
  still renderable while the text is hidden;
- the `codexShowUsageInMenuBar` preference persists through a store restart and
  defaults to visible;
- Refresh, Copy Status Summary, Open codexreset.org, and Quit wiring;
- updates while the menu is open edit existing items rather than replacing them.

The harness creates an `NSApplication` object only so `NSMenu` can dispatch item
actions. It never calls `run` or `finishLaunching`, never creates an
`NSStatusItem`, activates the app, shows a window, clicks anything, or launches
the app bundle. It also does not use screenshots, Accessibility UI inspection,
AppleScript, `CGWindowList`, or the `open` command.

**This is not a GUI test.** Actual menu-bar rendering/positioning, the real
status item's appearance, menu click/tracking behavior, opening a browser, and
process termination through `NSApplication` are not proven by this suite. Those
claims require desktop interaction and are deliberately not called verified.

`Tests/BundleTests.sh` decodes every representation of both `AppIcon.icns` files
and every iconutil-extracted size to prove each contains nontransparent pixels.
It also validates the bundle's `Info.plist` identifiers, name, package type,
versions, minimum macOS, `LSUIElement`, icon declaration, copied icon, bundled
`LICENSE`/`NOTICE`, and code signature.

The menu bar icon asset is generated from the checked-in drawing script:

```sh
./Tools/generate-app-icon.swift Resources/AppIcon.icns
```

## Privacy and protocol

Only `initialize`, `initialized`, and `account/rateLimits/read` are sent. The
response's `accountId` is ignored and is not stored, displayed, or logged.
Verification output shows only the limit windows and `ordinaryUsageAllowed`
boolean.

The parser follows the Codex app-server v2 types (`RateLimitSnapshot`,
`RateLimitWindow`, and `GetAccountRateLimitsResponse`).

No analytics, accounts, tokens, captured site HTML, or local usage data are
included in this repository or in the app bundle. `.scratch/`, `build/`,
`.build/`, `dist/`, credentials, and local usage data are ignored by Git.

## Notes

This is an unofficial client. codexreset.org is a public HTML source whose page
format can change; the forecast parser can require an update. Early restoration
detection still depends on Codex's own reported usage and backend permission,
not on site predictions or social posts.

## Contributing, security, and license

- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)
- Licensed under the [MIT License](LICENSE). Attribution and trademark notes are
  in [NOTICE](NOTICE).

Codex, OpenAI, and related names and marks are trademarks of their respective
owners. This project is independent and is not affiliated with, endorsed by, or
sponsored by OpenAI.
