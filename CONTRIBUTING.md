# Contributing

Issues and pull requests are welcome. Please read this first.

- **The maintainer decides** what is merged, and when. A pull request may be declined, changed, or left open without a
  detailed reason. Nobody is obliged to review, answer, or release anything.
- **Scope today:** Claude + AmneziaVPN (Kill Switch off) on macOS 26. Please open an issue before starting a large change,
  especially for supporting other apps or VPNs (see the Roadmap in the README).
- **License:** by submitting a contribution you agree to license it under GPL-3.0-or-later, the license of this project,
  and you confirm that you have the right to do so.
- **Style:** match the surrounding code; keep it dependency-free (Foundation/AppKit/Darwin only); keep comments in English.
- **Safety bar:** every change to `pf` rules, the daemon, or the setuid helper must keep the design *fail-closed* and must
  be described with how you tested it (`netleash test`, plus switching the VPN off and on).
- **Privacy:** never put personal data in issues, logs, commits or code: no IP addresses, MAC addresses, usernames,
  hostnames, account names, or full file paths from your machine. Redact before pasting. Consider using a separate,
  non-identifying git identity.
- **Bug reports:** include macOS version, VPN app version, output of `netleash status`, and the relevant lines of
  `/var/log/netleash.log` (redacted).

## Pull request expectations

- One focused change per pull request, with a clear description of the problem and how you tested it.
- Drive-by reformatting, mass renames and unrelated changes will be declined.
- CI (build) must be green. Be patient: reviews are best-effort and may take weeks. Pinging the maintainer does not speed things up.
