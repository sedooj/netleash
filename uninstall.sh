#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run: sudo ./uninstall.sh"; exit 1; }
N=netleash
LABEL=org.netleash.daemon
AGENT_LABEL=org.netleash.app
U="${SUDO_USER:-$(stat -f %Su /dev/console)}"; UID_=$(id -u "$U")
/usr/local/libexec/$N/panic.sh >/dev/null 2>&1 || true
launchctl bootout system/$LABEL 2>/dev/null || true
launchctl asuser "$UID_" launchctl bootout "gui/$UID_/$AGENT_LABEL" 2>/dev/null || true
pkill -u "$UID_" -f "Netleash.*Contents/MacOS" 2>/dev/null || true
rm -f "/Users/$U/Library/LaunchAgents/$AGENT_LABEL.plist" /Library/LaunchDaemons/$LABEL.plist /usr/local/bin/netleash
rm -rf /usr/local/libexec/$N /usr/local/etc/$N /var/run/$N "/Applications/Netleash.app"
dseditgroup -o delete _netleash 2>/dev/null || true
echo "Uninstalled. The main pf ruleset of the system and of your VPN app was left untouched."
