<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/svg/logo-horizontal-dark.svg">
    <img alt="Netleash" src="brand/svg/logo-horizontal.svg" height="72">
  </picture>
</p>

<p align="center"><b>English</b> · <a href="README.ru.md">Русский</a></p>

# Netleash

*A kernel-level network leash for macOS apps: an application may reach the network only through the route you choose.*

> **Unofficial, experimental, unaudited.** Not affiliated with, endorsed by, or sponsored by Anthropic or Amnezia.
> Read the [Disclaimer](#disclaimer) and the [Limitations](#limitations) before installing. This software installs a
> root daemon and a setuid helper on your Mac.

Netleash confines **selected applications' network access to a VPN tunnel**, at the kernel level (macOS `pf`).
If the VPN drops, that application loses the network *in the same instant*; when the VPN returns, the network returns.

## Supported configuration (read this first)

This checkout adds configurable protected applications. Build from source to use these changes; the one-line installer still downloads published upstream releases.

The VPN mechanism and its existing validation remain the same:

| Component | Supported |
|---|---|
| Protected applications | Original **Claude** and **Codex** desktop bundles, plus any `.app` selected in the applications window. Multiple apps can be enabled together; Claude remains the legacy default |
| VPN | **AmneziaVPN** (`/Applications/AmneziaVPN.app`, tested with 5.x) |
| AmneziaVPN **Kill Switch** | **must be OFF** (see [why](#why-the-amnezia-kill-switch-must-be-off)) |
| OS | macOS 26 (Tahoe), Apple Silicon (arm64). Other versions and Intel Macs are untested |

Codex and custom apps are configurable, but their live VPN behaviour has not yet been validated. The previous
upstream validation covers Claude + AmneziaVPN on macOS 26 / Apple Silicon. Keep the limitations below in mind.

## Launch protected apps through Netleash

Open **Netleash** to see the applications window. On first launch, click **Install…** to install the protection service; the app includes its own installer and asks for administrator access. The first installation starts with an empty list. General preferences live in a separate **Settings…** window with General, Updates, and Diagnostics tabs. Use **Add Claude**, **Add Codex**, or **Choose application…**.
Quit an app before adding or enabling it, saving your work first. Each app has its own protection switch and status.
Changes ask for administrator access and restart the daemon without removing the existing pf rules.

Launch enabled apps through **menu bar N → Applications → Open Claude / Open Codex**, the Open button in the applications window,
or `netleash apps launch /Applications/Codex.app`. Netleash reads the executable from the original bundle's Info.plist;
it never copies, patches, or renames the application and creates no “VPN” duplicate. Opening Netleash itself shows the applications window.
A running protected app is brought to the front rather than launched twice.

Optional desktop launchers: click **Shortcut…** next to an installed app in the applications window. Choose the Desktop or another
folder; the suggested name is the original app name, with its original icon and no VPN suffix. This creates a native Finder alias to a small signed launcher stored in `~/Library/Application Support/Netleash/Launchers`, not a copy of Claude/Codex. The signed app stays outside synced Desktop folders, whose file-provider metadata can invalidate code signatures. Double-clicking it hands the launch to the installed Netleash app;
protection checks still apply. You can also create it from a script after installing Netleash:

```bash
/Applications/Netleash.app/Contents/MacOS/Netleash --create-shortcut \
  /Applications/Claude.app "$HOME/Desktop/Claude.alias"
```

Shortcut creation needs no administrator access and refuses to overwrite an existing file. Removing a shortcut
leaves the original app and its protection settings intact.

**Opening an enabled app directly** (its own Dock icon, Spotlight, Finder, a login item, or an auto-update relaunch)
**still gets it terminated within about 50 ms**. The current group-based protection requires the Netleash launcher.
There is an unprotected window before termination; this is not a transparent firewall like Vallum.

Turning protection off or removing an app stops enforcing future launches. Already confined processes retain their
restricted group: quit and reopen the app normally to remove confinement. Other enabled apps stay protected.
You can also remove all protection temporarily using **Emergency rollback** or `netleash panic`.

## Install

Pick one. All three install the same files. **Read what you are about to run:** the installer uses `sudo` to install a
root daemon and a setuid helper.

The installer **closes running enabled apps** (a normal quit first, then by force) and **reopens each one under
protection** after installation or update. Save your work first. An app containing the installer's own terminal
is left open so that the installer can finish. Disabled apps are left alone.

### Option 1 — one command

```bash
curl -fsSL https://github.com/sedooj/netleash/releases/latest/download/get.sh | sh
```

`get.sh` downloads the release archive, **verifies its SHA-256 checksum** (and refuses to continue on a mismatch),
extracts it to a temporary folder and runs the archive's `install.sh` with `sudo`. Pin a version with
`NETLEASH_VERSION=v1.2.3`. Piping a script from the internet into a shell is only as trustworthy as the source: if that
makes you uncomfortable, use option 2.

### Option 2 — download, verify, read, then install (recommended)

```bash
# 1. download the release assets from https://github.com/sedooj/netleash/releases/latest
#    (netleash-darwin-arm64.tar.gz and SHA256SUMS)
shasum -a 256 -c SHA256SUMS            # must print: netleash-darwin-arm64.tar.gz: OK
# optional: verify build provenance (GitHub CLI):
gh attestation verify netleash-darwin-arm64.tar.gz --repo sedooj/netleash
tar -xzf netleash-darwin-arm64.tar.gz
less netleash-darwin-arm64/install.sh  # read it
sudo netleash-darwin-arm64/install.sh
```

### Option 3 — build from source

Requires [Go](https://go.dev/dl/) and, for the menu bar app, Xcode or the Command Line Tools (`swiftc`).

```bash
git clone https://github.com/sedooj/netleash.git && cd netleash
./build.sh
sudo dist/netleash-darwin-arm64/install.sh
```

The release binaries are ad-hoc signed and **not notarized**. Files fetched by `curl` carry no quarantine flag, so
Gatekeeper does not interfere; if you download the archive in a browser and macOS refuses to run it, remove the flag with
`xattr -dr com.apple.quarantine netleash-darwin-arm64`.

### After installing

Open **Netleash** to manage the list, then **menu bar N → Applications** to launch each enabled app.
Existing configured applications are preserved when upgrading. A fresh installation starts with no protected applications; add Claude and Codex explicitly.

Then verify:

```bash
netleash version  # e.g. "netleash 0.1.0 (commit abc1234, built …, darwin/arm64)"
netleash status   # is protection armed, is the VPN alive
netleash test     # a forced connection through a physical interface MUST be blocked
```

and test manually: with Claude running, switch the VPN off — its network must stop at once — and on again — it must
recover without restarting the app. A response interrupted mid-stream cannot resume (its TCP connection died with the
tunnel); resend the message.

### Settings and diagnostics

Menu bar icon → **Settings…** opens a native preferences window:

- **General:** language, notifications, and start at login (available after installation).
- **Updates:** daily checks and a manual check, available after installation.
- **Diagnostics:** protection status, a bounded network test, and a log viewer. The network test sends HTTPS requests through the tunnel and physical interfaces; it is not a complete DNS/privacy audit.

Opening an uninstalled app is supported: the interface explains setup, disables unavailable actions, and offers installation from its bundled files. You can copy just `Netleash.app` out of the release folder. Cancelling administrator access does not apply changes. The log viewer handles missing and empty logs, and offers separate protection, UI, application-startup, and installation sources.

The language applies to both the app and the `netleash` command. Force it for one command with `NETLEASH_LANG=en|ru`.

### Privacy prompts of the protected app

macOS asks for access to Downloads, Documents, the screen, etc. in the name of the process that is *responsible* for the app.
Netleash starts Claude through a small tool (`netleash-spawn`) that makes Claude its own responsible process, so the prompts
should name **Claude**. If a prompt names `netleash-exec` or Netleash instead, allow it once there (System Settings →
Privacy & Security), or tell us in an issue: it depends on macOS internals.

### Versions

Netleash uses [Semantic Versioning](https://semver.org); see [CHANGELOG.md](CHANGELOG.md). A release is a git tag
`vX.Y.Z` whose number equals the `VERSION` file. `netleash version` and the menu bar app show it; builds from a
checkout are marked `X.Y.Z-dev+<commit>`.

### Update, rollback, uninstall

- **Update:** `netleash update` (or the menu bar icon → **Check for updates…**). It asks GitHub for the latest release,
  shows what is new, and — after you confirm — downloads it, **verifies its SHA-256 checksum**, and runs its installer
  (administrator password required). By default the requests go **through the VPN** (they run inside the same
  confinement as the protected app, so GitHub and your ISP do not learn this Mac's real address); if the VPN is down the
  check simply fails. Use `netleash update --direct` to connect outside the VPN, `--check` to only look. In the menu you
  can switch on a **daily check** (off by default; silent when the VPN is down). Netleash never updates itself without
  your confirmation. Running the install command again also updates everything in place.
- **Emergency rollback:** menu bar icon → *Emergency rollback*, or `netleash panic`. The daemon stops and stays disabled
  across reboots, and the pf rules are removed. Re-enable with *Restore protection* or `netleash resume`.
- **Uninstall:** `sudo /usr/local/libexec/netleash/uninstall.sh`

## How it works

The protected app is started by a launcher in a dedicated group, `_netleash` (every other group is dropped and cannot be
regained). A `pf` anchor then applies to that group:

1. allow loopback (except ports of well-known local proxies, which could bypass the VPN);
2. allow TCP/UDP **only** through the VPN's `utunN` interface;
3. `block drop quick` everything else.

The pass rule is bound to the interface *name*. When the tunnel disappears the rule simply stops matching, so the kernel
blocks the traffic with no polling and no race — even if the daemon has died. After the VPN reconnects, the daemon
(within ~0.5 s) points the rule at the new `utunN`.

**DNS** is resolved by the system's `mDNSResponder`, which is not in the protected group, so the anchor also contains
two rules that apply to everyone:

- the VPN's own DNS servers may never be queried through a physical interface (this happens briefly while the VPN
  connects). The addresses are detected **automatically** — private addresses from `scutil --dns` that have a host route
  through the VPN interface, excluding subnets directly attached to physical interfaces — and can also be set manually
  (`vpnDnsServers`);
- while the VPN is down **and** any confined process is running, *all* DNS (53/853) on physical interfaces is blocked, so no
  hostnames leave the machine. Other apps cannot resolve names during that time either.

The anchor lives in `com.apple/050.netleash`. Apple's stock `/etc/pf.conf` already references `anchor "com.apple/*"`,
so programs that reload the main ruleset do not remove it.

### Components

| Component | Language | Role |
|---|---|---|
| `netleash` (`cmd/netleash`) | Go | One binary: the root **daemon** (`netleash daemon`, started by launchd at boot) and the **CLI** (`status`, `test`, `panic`, `resume`, `update`, `log`, `run`, `apps`, `version`). The daemon detects the live VPN, maintains the anchor, restores pf references, kills protected-app processes started outside the launcher (checked every 50 ms), and notifies |
| `netleash-exec` (`cmd/netleash-exec`) | Go | Setuid helper: runs a command as *your* user with only the `_netleash` group; refuses to start if protection is not armed. It only ever lowers privileges |
| `Netleash.app` (`app/Netleash`) | Swift | Launcher for the protected app, menu bar status icon (green: VPN up · red: VPN down, app blocked · orange: protection not working), leak test, log viewer, start-at-login, emergency rollback / restore |
| `packaging/*.sh`, `get.sh` | shell | Installer, uninstaller, rollback scripts, bootstrap |

Pure logic (pf rule generation, parsing of `netstat`/`scutil`/`ifconfig`, config) lives in `internal/` with unit tests,
including tests that the generated rules are fail-closed.

## Configuration

`/usr/local/etc/netleash/config.json` (all keys optional):

| Key | Default | Meaning |
|---|---|---|
| `protectedApps` | absent | array of `{ "path": "/Applications/Codex.app", "enabled": true }`; omitted `enabled` means true. An explicit empty array protects no new apps |
| `protectedAppPath` | `/Applications/Claude.app` | legacy single-app fallback, used only when `protectedApps` is absent/null |
| `vpnAppPath` | `/Applications/AmneziaVPN.app` | VPN whose tunnel is the only allowed route |
| `enforceLauncherOnly` | `true` | kill protected-app processes started outside the launcher |
| `notify` | `true` | system notifications |
| `loopbackBlockPorts` | `[7890, 7891, 7892, 7897, 9090, 9097]` | local proxy ports the app must not reach |
| `vpnDnsServers` | `["100.64.0.1"]` | VPN DNS servers never allowed through physical interfaces |
| `autoDetectVpnDns` | `true` | detect more of them automatically |
| `ignoreCommandSubstrings` | `["/Squirrel.framework/"]` | paths inside the app that are not killed (updater) |

The settings UI and `apps` commands preserve other configuration keys and apply the change automatically:

```bash
netleash apps                         # JSON list
sudo netleash apps add /Applications/Codex.app  # quit Codex first
sudo netleash apps disable /Applications/Codex.app
sudo netleash apps enable /Applications/Codex.app
sudo netleash apps remove /Applications/Codex.app
netleash apps launch /Applications/Claude.app
```

All apps share the same VPN route and firewall policy. Separate VPNs or proxy settings per app are not implemented.
After manual JSON edits: `sudo launchctl kickstart -k system/org.netleash.daemon`.

## Why the Amnezia Kill Switch must be OFF

Amnezia's kill switch reloads the main `pf` ruleset *non-atomically* whenever the connection state changes. For ~10–30 ms
the ruleset is empty, and during that window the system resolver can leak DNS queries. For the protected app this
project provides the same function (and a stricter one), so the kill switch must be turned off. **Consequence:** other
applications on your Mac are no longer protected by Amnezia's kill switch if the VPN drops.

## Limitations

- **Live VPN validation currently covers Claude + AmneziaVPN with Kill Switch OFF.** Codex and custom app bundles
  require end-to-end testing; configuration support alone is not a guarantee of confinement for every helper.
- "VPN is alive" means: a process from the VPN app exists **and** its `utunN` interface carries a default-like route.
  A hung tunnel that still looks alive blocks nothing but also transfers nothing (no leak, but no connectivity).
- `pf` cannot filter ICMP by group; ICMP is not restricted (it carries no application data).
- Processes the app starts *through launchd* (`open`, `launchctl submit`, login items) get another gid and are not
  confined.
- A copy of the app started outside the launcher lives for up to ~50 ms before the daemon kills it. In that window it
  is not confined. Auto-updates relaunch the app unprotected; it is killed and you start it again via the launcher.
- While the VPN is down and any confined process is running, DNS is blocked **system-wide** on physical interfaces.
- The local network is not reachable from the protected app.
- Not designed to resist a malicious process with root privileges, a malicious administrator, or a compromised OS.
- Updates trust this repository's GitHub releases: the checksum comes from the same release, so it protects against
  corrupted or tampered downloads, not against a compromised repository or account. For stronger assurance verify the
  build-provenance attestation (`gh attestation verify`, see Install, option 2).
- Unaudited code; binaries are ad-hoc signed, not notarized.

## Disclaimer

**THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND**, express or implied, including but not limited to
the warranties of merchantability, fitness for a particular purpose, and non-infringement. In no event shall the authors or
contributors be liable for any claim, damages or other liability — including loss of data, loss of network
connectivity, account suspension, privacy or security incidents, or legal consequences — whether in an action of
contract, tort or otherwise, arising from, out of, or in connection with the software or its use. See sections 15–17 of
the [GNU GPL v3](LICENSE).

- **Not a security guarantee.** This tool reduces the risk that one application reaches the network outside a VPN. It does
  **not** guarantee anonymity, privacy, or the absence of leaks. Verify it yourself (`netleash test`, packet captures)
  and do not rely on it where a failure would have serious consequences.
- **It modifies your system:** it installs a root LaunchDaemon, a setuid-root helper, a local group, and `pf` rules. Bugs
  may disrupt your network. Use at your own risk; read the code first.
- **Third-party services and terms.** You are solely responsible for complying with the terms of service and usage policies of
  every service you use (including the availability rules for your region) and with the laws that apply to you,
  including any laws about VPN use. **This project is not a means of obtaining access to any service in violation of its
  terms or of applicable law, and must not be used or promoted as such.** It is a generic network-confinement tool.
- **Trademarks.** "Claude" and "Anthropic" are trademarks of Anthropic, PBC; "AmneziaVPN" is a trademark of its
  respective owner. They are used here only to describe compatibility. This is an independent, unofficial project.
  The Netleash logo and icons are original artwork under the same license as the code; no third-party artwork is
  distributed in this repository.
- **No support obligation.** Issues and pull requests are welcome, but the maintainer decides what is accepted and
  owes nobody a response, a fix, or a release schedule.

## Roadmap

Not implemented yet; nothing below is supported today:

- other VPN software and plain WireGuard/OpenVPN tunnels (generic "tunnel is up" detection);
- support with the Amnezia kill switch enabled (a layer that survives `pf` reloads);
- other operating systems (the core is Go with the platform-specific parts isolated; Linux would use a different
  firewall backend);
- notarized releases, more automated tests, more languages.

## Contributing & security

See [CONTRIBUTING.md](CONTRIBUTING.md), [SUPPORT.md](SUPPORT.md) and [SECURITY.md](SECURITY.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
