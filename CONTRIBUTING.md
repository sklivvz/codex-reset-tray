# Contributing to Codex Reset Tray

Thanks for helping improve Codex Reset Tray. This is a small, dependency-light
macOS menu-bar utility; focused bug reports and small pull requests are the most
useful contributions.

## Before you start

- Search existing issues and pull requests first.
- For a behavior change, open an issue that describes the user-visible change
  and the failure mode it addresses.
- Do not include credentials, tokens, Codex account identifiers, captured site
  HTML, or real usage data in an issue, commit, fixture, or log.
- Report security issues privately as described in [SECURITY.md](SECURITY.md),
  not in a public issue.

## Develop and test

Requirements: macOS 13 or later, Apple Command Line Tools with Swift, and the
`codex` CLI if you want to exercise the live app-server path.

```sh
./build.sh
./test.sh
./scripts/package-release.sh
```

`test.sh` is the required command-line gate. It covers parser and restoration
logic with fixtures, the tray menu model, an offscreen AppKit `NSMenu` harness,
the icon, the app bundle, and its signature. The AppKit harness must remain
offscreen: do not add desktop launches, clicks, screenshots, Accessibility UI
inspection, AppleScript, or code that controls another application to the test
suite.

Run the tests before opening a pull request and include the commands and result
in the description. If you change packaging, also run `package-release.sh` on
macOS and confirm that its read-only DMG validation passes.

## Code guidelines

- Keep the app AppKit-only and free of unnecessary dependencies.
- Preserve the privacy boundary: the app reads rate limits; it must not store or
  display `accountId`, credentials, or local account data.
- Keep user-visible strings, tooltips, and VoiceOver labels accurate and
  reasonably short.
- Keep menu item ordering stable while the menu is open.
- Add or update a focused test for behavior changes.
- Update `README.md` and `CHANGELOG.md` for user-visible changes.
- Keep generated build products, `dist/`, `.build/`, `.scratch/`, and local data
  out of commits.

## Pull requests

- Use a clear title and explain the problem and the fix.
- Keep unrelated formatting or refactoring out of the change.
- Confirm `./test.sh` passes.
- By contributing, you agree that your contribution is licensed under the
  project's [MIT License](LICENSE).
