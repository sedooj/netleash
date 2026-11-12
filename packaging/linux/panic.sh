#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
# Emergency rollback: stops the daemon, removes the nftables table and keeps the service disabled across reboots.
# To re-enable: netleash resume
[ "$(id -u)" = 0 ] || { echo "root required: sudo netleash panic"; exit 1; }
systemctl disable --now netleash.service 2>/dev/null
NFT="$(command -v nft || true)"
[ -z "$NFT" ] || "$NFT" delete table inet netleash 2>/dev/null
rm -f /var/run/netleash/status.json
echo "Rolled back: daemon stopped, nftables rules removed. Protected programs can now be started normally."
echo "Restore protection: netleash resume"
