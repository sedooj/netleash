#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
# Emergency rollback: removes all protection and restores pf to its pre-install state.
# To re-enable: netleash resume
N=netleash
LABEL=org.netleash.daemon
[ "$(id -u)" = 0 ] || { echo "root required: sudo netleash panic"; exit 1; }
launchctl disable system/$LABEL
launchctl bootout system/$LABEL 2>/dev/null
pfctl -a com.apple/050.$N -F all 2>/dev/null
TOK=/usr/local/etc/$N/pf-token
if [ -s $TOK ]; then pfctl -X "$(cat $TOK)" 2>/dev/null; rm -f $TOK; fi
# If only Apple's own anchors remain, pf is no longer needed.
if ! pfctl -sA 2>/dev/null | grep -v -E "^\s*(com\.apple|$N|$)" | grep -q .; then pfctl -d 2>/dev/null; fi
rm -f /var/run/$N/status.json
echo "Rolled back: daemon stopped, pf rules removed. The protected app can now be started normally."
echo "Restore protection: netleash resume"
