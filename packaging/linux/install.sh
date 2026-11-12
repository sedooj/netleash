#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
#
# Installs / updates Netleash (Linux, experimental) from the directory this script lives in:
#   sudo ./install.sh            (add -y or NETLEASH_YES=1 to skip the confirmation)
# This installs a root daemon (systemd service) and a setuid helper. Read the README (Disclaimer, Limitations) first.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo ./install.sh"; exit 1; }
trap '' HUP PIPE
cd "$(dirname "$0")"
[ -x netleash ] && [ -x netleash-exec ] || { echo "netleash binaries not found next to install.sh"; exit 1; }
command -v systemctl >/dev/null || { echo "systemd is required"; exit 1; }
command -v nft >/dev/null || { echo "nftables is required: install the 'nftables' package (nft command)"; exit 1; }
command -v curl >/dev/null || echo "note: curl is needed by 'netleash test' and 'netleash update'"

N=netleash
L=/usr/local/libexec/$N
GROUP=netleash

echo "Netleash $(./netleash version | awk '{print $2}') (Linux, experimental)"
echo "This installs a root daemon and a setuid helper (see README: Disclaimer, Limitations)."
echo "The tunnel interface is taken from \"vpnInterfaces\" in /usr/local/etc/$N/config.json (default: amn0)."
if [ "${1:-}" != "-y" ] && [ "${NETLEASH_YES:-}" != "1" ]; then
  read -r -p "Continue? [y/N] " a || a=n
  [ "$a" = y ] || { echo "Aborted."; exit 1; }
fi

# 1. Group
getent group $GROUP >/dev/null || groupadd --system $GROUP

# 2. Files
mkdir -p $L /usr/local/etc/$N /usr/local/bin
install -o root -g root -m 755 netleash $L/netleash
install -o root -g root -m 4755 netleash-exec $L/netleash-exec
for f in panic.sh resume.sh uninstall.sh; do install -o root -g root -m 755 $f $L/$f; done
ln -sf $L/netleash /usr/local/bin/netleash
[ -f /usr/local/etc/$N/config.json ] || echo '{"protectedApps":[]}' > /usr/local/etc/$N/config.json
chown root:root /usr/local/etc/$N/config.json; chmod 644 /usr/local/etc/$N/config.json

# 3. Daemon (starts at boot, before the network comes up)
cat > /etc/systemd/system/$N.service <<U
[Unit]
Description=Netleash daemon (confines selected programs to a VPN tunnel)
Wants=network-pre.target
Before=network-pre.target

[Service]
ExecStart=$L/netleash daemon
Restart=always
RestartSec=1
StandardOutput=append:/var/log/$N.log
StandardError=append:/var/log/$N.log

[Install]
WantedBy=multi-user.target
U
chmod 644 /etc/systemd/system/$N.service
systemctl daemon-reload
systemctl enable $N.service >/dev/null 2>&1
systemctl restart $N.service

sleep 2
echo; netleash status || true
# `netleash update` unpacks the archive into a temporary directory of its own: remove it when done
case "$PWD" in */netleash-update-*/netleash-linux-*|*/netleash-install-*/netleash-linux-*) U="$(dirname "$PWD")"; cd /; rm -rf "$U" ;; esac
echo "Done. Add a program:  netleash apps add-cli claude    then run it:  netleash run claude   (or: netleash shell)"
echo "Check:  netleash test"
