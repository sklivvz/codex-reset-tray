## Download

Version 0.3.0 improves early-reset alerts, recovers from forecast page changes
and refresh failures, and adds a readable information window. Left-click the
tray icon for details; right-click for actions. The tray icon now uses the
packaged app artwork, with a compact gap before the optional 7-day label.
The actions menu and repository Sponsor button now link to the existing
PayPal.Me/sklivvz recipient page.

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

## Menu bar

The app icon is always visible. Left-click it for the information window and
right-click it for the actions menu. Use the native checked **Hide 7d Label** /
**Show 7d Label** item to hide or show the `7d 89%` usage text. The preference is saved in
`UserDefaults` and defaults to visible.

The DMG packaging script attaches the image read-only during validation, checks
the app bundle, versions, icon, both architectures, and ad-hoc signature, and
then detaches it. See the repository README for details and source.
