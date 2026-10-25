## Download

Version 0.2.0 adds a compact left-click information popover, moves all
configuration and actions into a native right-click menu, and hardens reset
notifications and forecast parsing.

The popover shows only the 7-day Codex usage headline and meter plus two large,
side-by-side reset forecasts for within 24 hours and within 48 hours. It has no
Codex usage section, latest confirmed reset, notification prose, version/build
text, or footer. Loading, stale, and error states keep the two forecast figures
and use normal label or readable error text rather than disabled gray. The
menu-bar glyph is a monochrome template derived from the packaged app icon; the
packaged app icon remains colored. A compact 4 pt gap separates the icon from
the optional 7-day label.

Right-click or control-click for an actions-only native menu with no heading or
informational rows: **Show 7d Label**, **Enable Notifications**, Refresh, Copy
Status Summary, Open codexreset.org, Support this project, **About Codex Reset
Tray**, and Quit. **Show 7d Label** keeps that exact title in both states; its
native check mark follows visibility, starting checked while the `7d 89%` text
is visible and clearing when it is hidden, while the menu-bar icon always
remains. The choice persists in `UserDefaults`. **Enable Notifications** is
checked only when macOS allows delivery; an undetermined click shows the system
permission prompt, while a denied or already-allowed click opens System Settings
> Notifications. The check mark refreshes when the menu opens and when the app
regains focus, and reset scheduling never prompts for permission. **About Codex
Reset Tray** opens the standard native About panel, and **Support this project**
(like the repository Sponsor button) opens
[PayPal.Me/sklivvz](https://paypal.me/sklivvz).

Reset notifications now cover normal scheduled 7-day rollovers as well as early
restorations. An advancing `resetsAt` is sufficient evidence even if usage has
already climbed in the new window, and a confirmed new window alerts from a 0%
baseline; prior usage gates only same-deadline usage-drop inference. Startup
state never alerts, and a per-deadline marker prevents duplicate requests. The
marker is committed only after the scheduler accepts the request, so permission
or scheduling failures retain the prior baseline for retry. A foreground
presentation delegate keeps accepted alerts visible while the app is active, and
Copy Status Summary retains sanitized `NSError` domain/code diagnostics.

Forecast parsing handles the current codexreset.org timeline markup when the
account-level restoration status is absent, labels global-only confirmations as
global instead of claiming the monitored account was restored, and strictly
validates timestamps and probabilities. A failed refresh keeps the previous two
probabilities visible as stale with a readable error line; opening either
surface retries after a failure. Forecasts remain informational and never
trigger notifications.

Download the universal macOS DMG (Apple Silicon and Intel) and its `.sha256`
checksum from the assets below.

Verify after download:

```sh
shasum -a 256 -c CodexResetTray-*.dmg.sha256
```

## Install

1. Open the DMG.
2. Drag **Codex Reset Tray** onto the **Applications** shortcut.
3. Launch it from Applications.

Requires macOS 13 or later and the `codex` CLI signed in with ChatGPT auth. The
app reads your local Codex app-server; no account credentials are collected.

This is an ad-hoc-signed build, not a notarized Developer ID build. On first
launch macOS may require right-click **Open**, or **System Settings > Privacy &
Security > Open Anyway**.

The DMG packaging script attaches the image read-only during validation, checks
the app bundle, versions, icon, both architectures, and ad-hoc signature, and
then detaches it. See the repository README for details and source.
