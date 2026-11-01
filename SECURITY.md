# Security policy

This project installs a root daemon and a setuid-root helper, so security reports are taken seriously, but it is an
unaudited hobby project maintained on a best-effort basis.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** (repository → *Security* → *Report a vulnerability*).
Do not open a public issue for anything that could be exploited. Include the affected component, macOS version,
and steps to reproduce. **Do not include personal data** (IP addresses, usernames, hostnames, account names).

You can expect a best-effort response; there is no guaranteed timeline or bounty.

## Scope

In scope: privilege escalation through `netleash-exec` or the daemon, ways to make the confined application reach
the network outside the VPN tunnel (leaks), ways to disable protection without administrator rights.

Out of scope: attacks requiring root, a compromised OS, physical access, and the documented
[limitations](README.md#limitations) (ICMP, processes started through launchd, DNS of other applications, etc.).
