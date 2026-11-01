#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
# Restores protection after panic.sh.
LABEL=org.netleash.daemon
[ "$(id -u)" = 0 ] || { echo "root required: netleash resume"; exit 1; }
launchctl enable system/$LABEL
for _ in 1 2 3 4 5; do
  launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist 2>/dev/null && break
  launchctl print system/$LABEL >/dev/null 2>&1 && break
  sleep 1
done
sleep 2
echo "Protection restored."
