# Netleash

*A kernel-level network leash for macOS apps: an application may reach the network only through the route you choose.*

> **Unofficial, experimental, unaudited.** Not affiliated with, endorsed by, or sponsored by Anthropic or Amnezia.
> Read the [Disclaimer](#disclaimer) and the [Limitations](#limitations) before installing. This software installs a
> root daemon and a setuid helper on your Mac.

Netleash confines **one application's network access to a VPN tunnel**, at the kernel level (macOS `pf`).
If the VPN drops, that application loses the network *in the same instant*; when the VPN returns, the network returns.

## Supported configuration (read this first)

Right now the project works **only** with this exact stack:

| Component | Supported |
|---|---|
| Protected application | **Claude desktop app** (`/Applications/Claude.app`) — chat, Claude Code, agents, the built-in browser, MCP servers and everything they spawn |
| VPN | **AmneziaVPN** (`/Applications/AmneziaVPN.app`, tested with 5.x) |
| AmneziaVPN **Kill Switch** | **must be OFF** (see [why](#why-the-amnezia-kill-switch-must-be-off)) |
| OS | macOS 26 (Tahoe), Apple Silicon. Other versions are untested |
| Build tools | Xcode or the Command Line Tools (`swiftc`) |

Anything else (other apps, other VPNs, other macOS versions) is **unsupported and untested**. Support for other
applications (e.g. Codex) and other VPNs is planned, see the [Roadmap](#roadmap).

## How it works

The protected app is started by a launcher in a dedicated group, `_netleash` (every other group is dropped and
cannot be regained). A `pf` anchor then applies to that group:

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
- while the VPN is down **and** the protected app is running, *all* DNS (53/853) on physical interfaces is blocked, so no
  hostnames leave the machine. Other apps cannot resolve names during that time either.

The anchor lives in `com.apple/050.netleash`. Apple's stock `/etc/pf.conf` already references
`anchor "com.apple/*"`, so programs that reload the main ruleset do not remove it.

## Components

| Component | Role |
|---|---|
| **Netleash.app** (`Sources/Netleash`) | The only app: launches the protected app under protection, menu bar status icon (green: VPN up · red: VPN down, app blocked · orange: protection not working), leak test, log viewer, start-at-login, emergency rollback / restore |
| `netleashd` | Root daemon (LaunchDaemon, starts at boot): detects the live VPN, maintains the anchor, restores pf references, kills protected-app processes started outside the launcher (checked every 50 ms), notifies |
| `netleash-exec` | Setuid helper: runs a command as *your* user with only the `_netleash` group; refuses to start if protection is not armed |
| `netleash` | CLI: `status`, `test`, `panic`, `resume`, `log`, `run <command…>` |

## Install

Requirements: see [Supported configuration](#supported-configuration-read-this-first). **Read the source before running
an installer that uses `sudo`** — it is short.

```bash
./build.sh && sudo ./install.sh
```

The installer terminates any Claude started outside the launcher. Save your work (including a Claude Code session
running inside Claude) first. Afterwards always start Claude via **Netleash**
(double-click, Dock, Spotlight, or the menu bar icon → *Open Claude*). Opening the launcher repeatedly does not create
new daemons or a second Claude: there is one daemon per system, and a running Claude is just brought to the front.

Do not publish or redistribute built binaries from your own machine; build from source or use CI artifacts.

## Verify

```bash
netleash status   # is protection armed, is the VPN alive
netleash test     # a forced connection through a physical interface MUST be blocked
```

Then test manually: with the protected app running, switch the VPN off — its network must stop at once — and on again —
it must recover without restarting the app. A response interrupted mid-stream cannot resume (its TCP connection died with
the tunnel); resend the message.

## Emergency rollback

Menu bar icon → *Emergency rollback*, or `netleash panic`. The daemon stops and stays disabled across reboots, and
the pf rules are removed. Re-enable with *Restore protection* or `netleash resume`. Full removal: `sudo ./uninstall.sh`.

## Configuration

`/usr/local/etc/netleash/config.json` (all keys optional):

| Key | Default | Meaning |
|---|---|---|
| `protectedAppPath` | `/Applications/Claude.app` | application to confine |
| `vpnAppPath` | `/Applications/AmneziaVPN.app` | VPN whose tunnel is the only allowed route |
| `enforceLauncherOnly` | `true` | kill protected-app processes started outside the launcher |
| `notify` | `true` | system notifications |
| `loopbackBlockPorts` | `[7890, 7891, 7892, 7897, 9090, 9097]` | local proxy ports the app must not reach |
| `vpnDnsServers` | `["100.64.0.1"]` | VPN DNS servers never allowed through physical interfaces |
| `autoDetectVpnDns` | `true` | detect more of them automatically |
| `ignoreCommandSubstrings` | `["/Squirrel.framework/"]` | paths inside the app that are not killed (updater) |

After editing: `sudo launchctl kickstart -k system/org.netleash.daemon`.

## Why the Amnezia Kill Switch must be OFF

Amnezia's kill switch reloads the main `pf` ruleset *non-atomically* whenever the connection state changes. For ~10–30 ms
the ruleset is empty, and during that window the system resolver can leak DNS queries. For the protected app this
project provides the same function (and a stricter one), so the kill switch must be turned off. **Consequence:** other
applications on your Mac are no longer protected by Amnezia's kill switch if the VPN drops.

## Limitations

- **Only Claude + AmneziaVPN with Kill Switch OFF is supported.** Other combinations are untested and may leave the app
  permanently blocked or unprotected.
- "VPN is alive" means: a process from the VPN app exists **and** its `utunN` interface carries a default-like route.
  A hung tunnel that still looks alive blocks nothing but also transfers nothing (no leak, but no connectivity).
- `pf` cannot filter ICMP by group; ICMP is not restricted (it carries no application data).
- Processes the app starts *through launchd* (`open`, `launchctl submit`, login items) get another gid and are not
  confined.
- A copy of the app started outside the launcher lives for up to ~50 ms before the daemon kills it. In that window it
  is not confined. Auto-updates relaunch the app unprotected; it is killed and you start it again via the launcher.
- While the VPN is down and the protected app is running, DNS is blocked **system-wide** on physical interfaces.
- The local network is not reachable from the protected app.
- Not designed to resist a malicious process with root privileges, a malicious administrator, or a compromised OS.
- Unsigned, un-notarized, un-audited code. The installer ad-hoc signs binaries locally.

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
  The launcher copies the app icon from *your own* installed Claude.app at install time; no third-party artwork is
  distributed in this repository.
- **No support obligation.** Issues and pull requests are welcome, but the maintainer decides what is accepted and
  owes nobody a response, a fix, or a release schedule.

## Roadmap

Not implemented yet; nothing below is supported today:

- other protected applications (e.g. Codex) via configuration instead of constants;
- other VPN software and plain WireGuard/OpenVPN tunnels (generic "tunnel is up" detection);
- support with the Amnezia kill switch enabled (a layer that survives `pf` reloads);
- signed and notarized releases, automated tests, localization.

## Contributing & security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
