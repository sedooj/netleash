# Changelog

Versions follow [Semantic Versioning](https://semver.org). The version of a release is the content of the `VERSION`
file and the git tag `vX.Y.Z`; local builds are marked `X.Y.Z-dev+<commit>`.

## Unreleased

- Configurable protected app list: add Claude, Codex, or another original app bundle in the applications window, enable/disable
  protection per app, and launch from the Applications menu without making copies or changing application signatures.
- `netleash apps` commands to list, add, enable, disable, remove, and launch app bundles. Settings changes preserve
  unrelated configuration, require administrator access, and restart the daemon without removing pf rules.
- Preserve legacy `protectedAppPath` configurations; installers close and reopen each configured enabled app.
- Keep the DNS lock while any confined process remains, including child commands after their parent app exits.
- Separate native macOS preferences window with General, Updates, and Diagnostics toolbar tabs; resizable
  application list with right-aligned actions, truncation, scrolling, and narrow/wide layout regression tests.
- Self-contained first-run installation from Netleash.app. Fresh installs start with an empty app list; upgrades
  preserve existing configuration. Unavailable actions and administrator cancellation have explicit UI states.
- Fix GUI installation failing before install.sh (`nohup: can't detach from console`): start the installer in a new
  process session and capture both output streams, including launch failures, in the installation log. Build validation
  executes a harmless probe through the same AppleScript transport; regression tests cover detachment and log safety.
- Bounded command execution with regression tests for failed spawns, inherited stdout, timeout, and retry.
  The network check reports incomplete tests and no longer hangs when the CLI is missing.
- Native log viewer with four sources, bounded tail reads, and explicit missing/empty/unreadable-file states.
- Optional desktop Finder aliases with original app names and icons, created from the applications window or with
  `Netleash --create-shortcut <original.app> <shortcut.alias>`. Signed launchers live in Application Support so synced
  Desktop metadata cannot invalidate their signatures. Source apps are never copied or modified, and existing files
  are never overwritten. Shortcuts always hand launches to Netleash for protection checks.
- Preserve original .icns assets and fix Retina bitmap fallback scaling. Clean signing-incompatible metadata only
  from generated bundles, preserve unrelated attributes, and roll back failed shortcut creation.
- Allow creating shortcuts while protection is off; explain disabled protection when a shortcut is opened.
- Codex/custom-app live VPN validation is still pending; ordinary direct launches retain the existing 50 ms limitation.

## 0.2.2 — 2026-11-01

- New **Settings** window in the menu bar app: language (system / English / Russian, also used by the `netleash`
  command), Netleash banners, daily update check, "Check for updates…", start at login. These items moved out of the menu;
  the menu now shows Open Claude, leak test, log, Settings…, rollback / restore and Quit (plus "Update available" when one is
  known).
- Fix: privacy prompts of the protected app named `netleash-exec`. Claude is now started through `netleash-spawn`, a small
  non-setuid tool that makes it its own "responsible process" (the prompt should name Claude).
- Fix: updating from the menu bar app could stop halfway when the installer restarted the app, so Claude was not
  reopened. The installer now ignores its caller going away and logs to `/var/log/netleash-install.log`; the app starts it
  detached (`/var/log/netleash-update.log`); the temporary update directory is removed afterwards.

## 0.2.1 — 2026-11-01

- Russian localization: the menu bar app (menus, dialogs, banners, notifications) and the command-line output
  (`status`, `test`, `update`, help) follow the system language; override with `NETLEASH_LANG=en|ru`. Documents have
  Russian versions (`README.ru.md`, `CONTRIBUTING.ru.md`, `SECURITY.ru.md`, `SUPPORT.ru.md`, `CODE_OF_CONDUCT.ru.md`).
- Tests that translations keep their format placeholders (`internal/i18n`, `app/check-l10n.py`).

## 0.2.0 — 2026-11-01

- `netleash update`: checks GitHub for a newer release and, after confirmation, downloads it, verifies its SHA-256
  checksum and runs its installer. Requests go **through the VPN** by default (`--direct` to bypass; `--check`,
  `--json`, `--yes`, `--download-only`, `--version` available).
- Menu bar app: "Check for updates…" with a one-click update flow, and an opt-in daily check (off by default;
  silent when the VPN is down).
- Notifications (VPN down/up, unprotected launch closed, update available) are now shown by the Netleash app under its
  own name and icon instead of "Script Editor". The daemon publishes events in its status file; if the menu bar app is
  not running it falls back to the old mechanism. macOS asks for notification permission on first start; the menu
  bar app is now started through LaunchServices (required for macOS to register it for notifications), logs why a
  notification did or did not appear to `~/Library/Logs/Netleash.log`, and, when macOS does not allow notifications for
  the app (common for ad-hoc signed apps), shows its own banner (top right, with the Netleash icon) instead.
  New menu item: Notification settings…
- The installer now closes Claude by itself (normal quit first, then by force) and reopens it through Netleash when it
  finishes, on installs and updates. It does not do this when it is run from a terminal inside Claude (that would end
  the installer), and it ignores the terminal hang-up while Claude closes.
- The protected app is now started so that macOS treats it as its own "responsible process" (the launcher disclaims
  responsibility). Before, privacy prompts (Downloads, Documents, …) named Netleash instead of the app, and permissions
  already granted to the app did not apply.
- Unit tests for version comparison, checksum verification and safe archive extraction.

## 0.1.0 — 2026-11-01

First public version. Supported setup: Claude desktop app + AmneziaVPN (Kill Switch off), macOS 26, Apple Silicon.

- Kernel-level confinement of the protected app's network to the VPN tunnel (`pf` anchor, dedicated group).
- Root daemon and CLI in Go (`netleash`), setuid helper (`netleash-exec`), menu bar app in Swift.
- DNS leak protection with automatic detection of the VPN's DNS servers.
- Emergency rollback (`netleash panic`) and restore (`netleash resume`).
- Release archive with SHA-256 checksums and a `curl | sh` bootstrap installer.
- Original logo, app icon and menu bar glyphs.
