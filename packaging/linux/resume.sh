#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
# Restores protection after panic.sh.
[ "$(id -u)" = 0 ] || { echo "root required: netleash resume"; exit 1; }
systemctl enable --now netleash.service
sleep 2
echo "Protection restored."
