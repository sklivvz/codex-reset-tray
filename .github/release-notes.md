## Download

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

The bar-chart icon is always visible. Use the native checked **Show Usage in Menu
Bar** item to show or hide the `7d 89%` usage text. The preference is saved in
`UserDefaults` and defaults to visible.

The DMG packaging script attaches the image read-only during validation, checks
the app bundle, versions, icon, both architectures, and ad-hoc signature, and
then detaches it. See the repository README for details and source.
