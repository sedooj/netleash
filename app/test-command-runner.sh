#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/netleash-command-tests.XXXXXX")
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
swiftc app/Netleash/CommandRunner.swift app/Netleash/ApplicationRowLayout.swift app/Netleash/ShortcutMetadata.swift app/tests/CommandRunnerTests.swift app/tests/ShortcutMetadataTests.swift -o "$TASK_TEST_DIR/command-tests"
"$TASK_TEST_DIR/command-tests"
