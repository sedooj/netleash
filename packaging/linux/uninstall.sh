#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
#
# Removes Netleash:  sudo /usr/local/libexec/netleash/uninstall.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
/usr/local/libexec/netleash/panic.sh >/dev/null 2>&1 || true
rm -f /etc/systemd/system/netleash.service /usr/local/bin/netleash
systemctl daemon-reload
rm -rf /usr/local/libexec/netleash /usr/local/etc/netleash /var/run/netleash
groupdel netleash 2>/dev/null || true
echo "Uninstalled."
