# Security Policy

## Supported versions

Security fixes are provided for the latest published `0.1.x` release. Older
builds may not receive fixes.

## Reporting a vulnerability

Please report security issues privately through GitHub Security Advisories:

<https://github.com/sklivvz/codex-reset-tray/security/advisories/new>

Do **not** open a public issue, pull request, or discussion for a suspected
vulnerability, and do not attach credentials, tokens, account identifiers,
captured site HTML, or real usage data.

Include:

- the affected version or commit;
- macOS version and architecture;
- a minimal description of the issue and its impact;
- reproduction steps or a proof of concept that contains no secrets; and
- any suggested mitigation.

The maintainer will acknowledge the report as soon as practical and coordinate
disclosure after a fix is available.

## Scope and security model

Codex Reset Tray is a local, unofficial menu-bar utility. It:

- reads Codex rate limits through the user's local `codex app-server`;
- fetches the public codexreset.org page for informational forecasts;
- stores its baseline and the `codexShowUsageInMenuBar` preference in the app's
  `UserDefaults` domain; and
- does not collect analytics or send account identifiers.

Reports about exposed credentials, unsafe subprocess invocation, unexpected
network requests, bundle tampering, or a release asset that does not match its
published checksum are in scope.

The released app is ad-hoc signed and not notarized. A Gatekeeper warning on
first launch is expected; follow the installation note in the README rather than
bypassing macOS protections for an unexpected or checksum-mismatched download.
