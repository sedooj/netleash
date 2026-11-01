#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
# Builds everything into ./build (no sudo needed). Requires Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
# -file-prefix-map keeps the local checkout path out of the binaries
MAP="-file-prefix-map $PWD=."
swiftc -O $MAP Sources/netleashd/main.swift      -o build/netleashd
swiftc -O $MAP Sources/netleash-exec/main.swift  -o build/netleash-exec
swiftc -O $MAP Sources/Netleash/main.swift -framework AppKit -o build/Netleash
echo "OK: build/netleashd build/netleash-exec build/Netleash"
