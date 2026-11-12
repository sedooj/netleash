#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
#
# Runs the Linux end-to-end test in a privileged Ubuntu container (needs Docker; the container's kernel provides
# nftables). Builds the archive for the container's architecture first.
set -euo pipefail
cd "$(dirname "$0")/../.."
case "$(docker info --format '{{.Architecture}}')" in aarch64|arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
NETLEASH_OS=linux NETLEASH_ARCH=$ARCH NETLEASH_KEEP_DIST=1 ./build.sh >/dev/null
docker run --rm --privileged -v "$PWD/dist:/dist:ro" -v "$PWD/test/linux/e2e.sh:/e2e.sh:ro" ubuntu:24.04 \
  bash /e2e.sh "/dist/netleash-linux-$ARCH.tar.gz"
