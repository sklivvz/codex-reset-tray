# Codex Reset Tray

[![CI](https://github.com/sklivvz/codex-reset-tray/actions/workflows/ci.yml/badge.svg)](https://github.com/sklivvz/codex-reset-tray/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/sklivvz/codex-reset-tray)](https://github.com/sklivvz/codex-reset-tray/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small macOS menu-bar app that watches **your own Codex quota** through the
local `codex app-server` and notifies you when the 7-day usage window resets,
whether that happens at its scheduled deadline or early. It also shows
[codexreset.org](https://codexreset.org/) forecasts in the left-click
information popover, but those forecasts are informational and never trigger
notifications.

## Download for macOS

[**Download Codex Reset Tray v0.1.0 — Universal (Apple Silicon + Intel)**](https://github.com/sklivvz/codex-reset-tray/releases/download/v0.1.0/CodexResetTray-v0.1.0-macos-universal.dmg)

- Direct DMG: [`CodexResetTray-v0.1.0-macos-universal.dmg`](https://github.com/sklivvz/codex-reset-tray/releases/download/v0.1.0/CodexResetTray-v0.1.0-macos-universal.dmg)
- SHA-256: [`CodexResetTray-v0.1.0-macos-universal.dmg.sha256`](https://github.com/sklivvz/codex-reset-tray/releases/download/v0.1.0/CodexResetTray-v0.1.0-macos-universal.dmg.sha256)
- All releases: <https://github.com/sklivvz/codex-reset-tray/releases>

The changes described below are in the current source. The v0.1.0 download does
not include them; the next release is being held for local validation.

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

## Two surfaces: information and actions

The menu-bar item always shows a monochrome template glyph derived from the
packaged `AppIcon.icns` (the packaged app icon remains colored). By default it
also shows the current 7-day usage text, for example `7d 89%`, a compact 4 pt to
the right of the icon.

There are exactly two surfaces:

- **Left click** opens one anchored transient `NSPopover` below the menu-bar
  item. It contains all status, usage-window, reset, notification, and forecast
  data, including errors, last-check times, and the current label setting. It
  updates while open and closes transiently when you click elsewhere.
- **Right click** (or control-click) first dismisses the open information
  popover, then opens one native `NSMenu` containing only configuration and
  actions: the 7d label toggle, Refresh, Copy Status Summary, Open
  codexreset.org, Support this project, and Quit. The menu has no heading and no
  informational rows. A single native separator before Quit is the only
  structural element retained.

Native gray text means an action is genuinely disabled. The actions menu never
uses gray for status or to de-emphasize information, because it contains none.

- **Hide 7d Label** is the first checked action in the menu.
- It is checked by default. Selecting it hides the `7d 89%` text, clears the
  check mark, and changes the item to **Show 7d Label**, leaving only the icon.
- The choice persists in `UserDefaults` under the key
  `codexShowUsageInMenuBar` and is restored on the next launch.
- The icon itself is never hidden by this setting, including in error states.

The offscreen AppKit tests exercise both states, the native check mark, the
retained icon, and persistence across store restarts. They also assert that the
menu model contains no information rows while the popover model contains all of
them. The offscreen suite does not exercise the real menu-bar item or observe
the screen; the opt-in live check below covers those paths.

## Behavior

### Codex usage: source of truth

- Immediately after launch and then every 5 minutes, the app starts a local
  `codex app-server --listen stdio://`, performs the JSON-RPC `initialize`
  handshake, and calls `account/rateLimits/read`. It only reads usage; it does
  not log in, log out, or modify account state.
- Each call has a hard 10-second deadline. A missing binary, launch failure, RPC
  error, timeout, or malformed response is shown in the left-click information
  popover and can never produce a notification.
- The 7-day window is identified by `windowDurationMins == 10080`, whichever
  slot (`primary` or `secondary`) contains it. This matters because Codex has
  returned the weekly window as `primary` on some accounts. The window's
  `resetsAt` is used as the prior reset deadline.

### Reset notification

The app persists the latest 7-day usage baseline in `UserDefaults` under
`codexWeeklyUsageBaselineV2`: prior used percentage, prior `resetsAt`, capture
time, and an "already notified" marker for that reset deadline. A notification is
considered only when **all** of these are true:

1. This launch has already established a session baseline. The first successful
   reading after launch only adopts current state and never alerts, even when a
   persisted baseline exists, because that state may describe a reset that
   happened while the app was closed.
2. No notification has already been scheduled for that prior reset deadline.
3. Codex reports a genuine reset signal: either the new 7-day `resetsAt` is at
   least 5 minutes later than the prior deadline (a new window, whether scheduled
   or early), or, when prior usage was greater than 0%, current usage is at most
   25% and has fallen materially (at least 3 percentage points and at least half
   of the prior usage, or cleared to 1% or less from at least 2 points). A
   confirmed new window alerts even from a 0% baseline; the prior-usage
   requirement applies only to same-deadline usage-drop inference. The usage
   ceiling is deliberately above 1%: usage can be consumed again before the next
   poll after a reset. A deadline advancing is sufficient even when usage has
   already climbed in the new window.

A window change at or within 5 minutes before the prior deadline is reported as
the normal **scheduled** reset. A new window or a usage restoration before that
deadline is reported as an **early** reset. Merely reaching the old deadline with
no new deadline and no usage drop does not alert.

`ordinaryUsageAllowed` is reported in the notification, but it is not required
as evidence that the quota itself was restored. A false or missing value does not
suppress a genuine deadline or usage transition.

The notification is requested at most once per reset window. The persisted marker
is written only after the notification scheduler accepts the request. If
authorization is denied or scheduling fails, the prior baseline is retained so a
later poll can retry, and the information popover shows an error row with the
sanitized system error domain and code. The alert is not sent on startup
historical state, on a parse or transport failure, or because a codexreset.org
forecast changed.

*Scheduled* means macOS accepted a local notification request. It does not prove
that a banner was visually delivered; notification settings and Focus control
that. A foreground presentation delegate keeps the request visible while the
accessory app is active, and permission is requested only after the first usage
fetch and only when the status is still undecided. The information popover
reports both the permission/scheduling state and when the last notification
request was scheduled, with the reminder that visual delivery is controlled by
macOS.

The information popover shows primary/secondary windows, the persisted baseline
and deadline, notification permission/scheduling state, the latest forecast or
forecast error, and any Codex error. `ordinaryUsageAllowed`, the last read time,
and the last scheduled notification request are visible there and in row
tooltips. The right-click menu never duplicates these rows: it always contains
only the 7d label toggle, Refresh, Copy Status Summary, Open codexreset.org,
Support this project, and Quit. Every action is enabled, and Quit is last.

### codexreset.org forecast

- Forecasts are fetched when the information popover or actions menu opens, or
  when Refresh is pressed.
- Refresh also re-polls Codex usage immediately.
- The information popover shows 24-hour and 48-hour probabilities, the latest
  confirmed reset (and account-level restoration when the site reports it), and
  the forecast summary in its rows and tooltips.
- If the site only confirms a reset on its global timeline, the tooltip labels
  that as global and does not claim the monitored account was restored.
- A failed refresh keeps the last forecast visible as stale and shows when it
  was last updated. Opening either surface retries after a failure.
- The site is never consulted for notification decisions.

## Requirements

- macOS 13 or later
- Apple Command Line Tools with Swift (no Xcode project required)
- The `codex` CLI installed and signed in with ChatGPT auth
- A Codex app-server that supports the v2 `account/rateLimits/read` method

The app looks for `codex` in common install locations and on `PATH` (including
Homebrew paths, since Finder-launched apps get a minimal environment). Set
`CODEX_BINARY=/absolute/path/to/codex` to override discovery.

## Donations

**Support this project** in the tray menu opens
[PayPal.Me/sklivvz](https://paypal.me/sklivvz) in the default browser. The
recipient page identifies Marco Cecconi and accepts an amount entered by the
supporter. The app handles no payment information. The repository's Sponsor
button uses the same PayPal.Me destination.

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
- `test.sh` runs the Codex JSON/transition tests on fixtures, the pure
  actions-menu and information-popover model tests, an offscreen AppKit
  integration test, the parser smoke test on the checked-in fixture, and the
  bundle/icon/signature checks. Run `./build.sh` before `./test.sh` because the
  bundle test inspects the built app.
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

- the menu is nonempty before and on the first open and contains exactly the six
  configuration/actions rows plus the native separator before Quit;
- no informational status, usage, reset, notification, or forecast row appears
  in the menu model or in any native `NSMenuItem` title;
- every action is enabled and uses a plain native title, so gray can only ever
  mean a genuinely disabled action;
- the status button uses a monochrome template mask derived from the white
  chart and reset mark in `Resources/AppIcon.icns`, with the SF Symbol only as a
  fallback; the packaged app icon remains colored;
- the icon-label gap is 4 pt, measured from a laid-out button, and disappears
  with the label when it is hidden;
- left clicks through the button action open the information popover, and
  right/control-click mouse-downs through the event handler dismiss any open
  popover before opening the actions menu; the popover is an injected fake that
  records the real status-button anchor, and its content `NSView` is rendered
  offscreen;
- the production popover presenter is configured as `.transient` and hosts the
  same content view without creating a window before it is shown;
- the popover follows source updates while open; a transient close during the
  status-button click still completes the show/hide toggle; all informational
  rows and error tones remain in the popover model (error text meets WCAG AA
  contrast in light and dark);
- status, usage-window, baseline, reset, notification, forecast, and error data
  remain available in the popover model after being removed from the menu model;
- the checked **Hide 7d Label** / **Show 7d Label** toggle in both states, with
  the icon still renderable while the text is hidden;
- the `codexShowUsageInMenuBar` preference persists through a store restart and
  defaults to visible;
- Refresh, Copy Status Summary, Open codexreset.org, Support this project, and
  Quit wiring;
- updates while the menu is open edit existing items rather than replacing them;
- normal scheduled and early resets through `ResetStore`, including the
  per-window duplicate marker, with a deterministic fake notification scheduler;
- foreground presentation delegate registration, authorization pre-checks
  (already granted, undecided, denied), scheduling, and sanitized `NSError`
  domain/code diagnostics with a fake notification center.

`./test.sh` also compiles the opt-in live check at
`./.build/tray-menu-runtime-tests`. To run that check on a Mac with an active
GUI session, run `./.build/tray-menu-runtime-tests --live-status-item`. It
briefly creates a real `NSStatusItem` and sends synthetic mouse events through
a running `NSApplication`. It checks that left click shows a transient
information popover anchored to the real status button, renders every
informational row, follows a live update, and toggles closed on a second left
click. It then right-clicks while that popover is open, asserting the popover is
closed by the time the native actions menu opens, and separately sends a
control-left click through `NSApplication` to prove that route opens the same
actions-only menu without a popover. The menu is checked for exactly the six
configuration/actions rows, no informational titles, and all actions enabled.
It also verifies transient outside-click dismissal, runs under a bounded
watchdog, and removes the status item when done. This check is opt-in locally
because it touches the menu bar and briefly displays a popover.

CI runs this live harness on a GitHub-hosted `macos-15` runner after
`./build.sh` and `./test.sh`; the step fails the job on any non-zero harness
exit, including a watchdog timeout. This gives the two-surface behavior a real
AppKit event-loop check without requiring a developer desktop session.

The offscreen harness creates an `NSApplication` object only so `NSMenu` can
dispatch item actions. It never calls `run` or `finishLaunching`, never displays
an `NSStatusItem` or popover, activates the app, shows a window, clicks anything
on screen, or launches the app bundle. It also does not use screenshots,
Accessibility UI inspection, AppleScript, `CGWindowList`, or the `open` command.

**The default suite is not a GUI test.** Actual menu-bar rendering/positioning,
real user click/tracking behavior, opening a browser, and process termination
through `NSApplication` are not proven there. The opt-in live check covers the
real status button, popover show/hide/anchor, right-click popover dismissal
before the actions menu, and control-left menu opening with synthetic events,
but it is not a substitute for desktop interaction testing.

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
