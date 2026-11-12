#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
#
# Builds the release layout into dist/netleash-<os>-<arch>/ and packs dist/netleash-<os>-<arch>.tar.gz.
# Requires Go and (for the macOS menu bar app) Xcode or the Command Line Tools. No sudo needed.
#   ./build.sh                       local build:   0.1.0-dev+<commit>
#   NETLEASH_RELEASE=1 ./build.sh    release build: 0.1.0 (from the VERSION file)
#   NETLEASH_OS=linux NETLEASH_ARCH=amd64|arm64 NETLEASH_KEEP_DIST=1 ./build.sh    Linux archive (cross-compiled; keeps dist/)
set -euo pipefail
cd "$(dirname "$0")"

# Version: the VERSION file is the single source of truth (semantic version). Release builds (NETLEASH_RELEASE=1,
# set by the release workflow after it checks the tag) use it as is; local builds are marked "<version>-dev+<commit>".
BASE="$(tr -d '[:space:]' < VERSION)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ "${NETLEASH_RELEASE:-}" = "1" ]; then
  VERSION="$BASE"
else
  VERSION="$BASE-dev+$COMMIT"
  git diff --quiet HEAD 2>/dev/null || VERSION="$VERSION.dirty"
fi
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OS="${NETLEASH_OS:-darwin}"
case "$OS" in darwin|linux) ;; *) echo "unsupported OS: $OS"; exit 1 ;; esac
if [ -n "${NETLEASH_ARCH:-}" ]; then ARCH="$NETLEASH_ARCH"
else case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; *) echo "unsupported architecture"; exit 1 ;; esac; fi
NAME="netleash-$OS-$ARCH"
OUT="dist/$NAME"
if [ "${NETLEASH_KEEP_DIST:-}" = "1" ]; then rm -rf "$OUT" "dist/$NAME.tar.gz"; else rm -rf dist; fi
mkdir -p "$OUT"

echo "==> Netleash $VERSION ($OS/$ARCH)"
echo "==> Go binaries"
export CGO_ENABLED=0 GOOS="$OS" GOARCH="$ARCH"
# Tests run on the build machine; a cross-compiled target cannot execute them.
(unset GOOS GOARCH; go test ./...)
go build -trimpath -ldflags "-s -w -X main.version=$VERSION -X main.commit=$COMMIT -X main.date=$DATE" -o "$OUT/netleash" ./cmd/netleash
go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$OUT/netleash-exec" ./cmd/netleash-exec

if [ "$OS" = darwin ]; then
echo "==> Spawn tool"
clang -O2 -Wall -o "$OUT/netleash-spawn" cmd/netleash-spawn/spawn.c
fi

echo "==> Menu bar app"
if [ "$OS" != darwin ]; then
  echo "skipped (macOS only)"
elif command -v swiftc >/dev/null; then
  echo "==> UI command regression tests"
  app/test-command-runner.sh
  APP="$OUT/Netleash.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc -O -file-prefix-map "$PWD=." app/Netleash/*.swift -framework AppKit -framework UserNotifications -o "$APP/Contents/MacOS/Netleash"
  swiftc -O -file-prefix-map "$PWD=." app/NetleashLauncher/main.swift -framework AppKit -o "$APP/Contents/Resources/NetleashLauncher"
  cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleName</key><string>Netleash</string>
 <key>CFBundleDisplayName</key><string>Netleash</string>
 <key>CFBundleIdentifier</key><string>org.netleash.app</string>
 <key>CFBundleExecutable</key><string>Netleash</string>
 <key>CFBundleIconFile</key><string>icon.icns</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>$BASE</string>
 <key>CFBundleVersion</key><string>$VERSION</string>
 <key>CFBundleDevelopmentRegion</key><string>en</string>
 <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
 <key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Protected Application</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>None</string>
  <key>LSItemContentTypes</key><array><string>com.apple.application-bundle</string></array>
 </dict></array>
 <key>LSUIElement</key><true/>
 <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
P
  # Brand assets: app icon and menu bar glyphs (see brand/)
  cp brand/Netleash.icns "$APP/Contents/Resources/icon.icns"
  cp -R app/Netleash/Resources/ru.lproj "$APP/Contents/Resources/"
  mkdir -p "$APP/Contents/Resources/en.lproj"
  cp brand/png/menubar-up@2x.png brand/png/menubar-down@2x.png brand/png/menubar-warn@2x.png "$APP/Contents/Resources/"
  # Keep first-run installation available when the user copies only Netleash.app.
  mkdir -p "$APP/Contents/Resources/Installer"
  cp "$OUT/netleash" "$OUT/netleash-exec" "$OUT/netleash-spawn" "$APP/Contents/Resources/Installer/"
  cp packaging/*.sh "$APP/Contents/Resources/Installer/"
  chmod 755 "$APP/Contents/Resources/Installer/"*
  codesign -f -s - "$APP" 2>/dev/null || true
  echo "==> First-run installation payload check (installs nothing)"
  "$APP/Contents/MacOS/Netleash" --check-installer
else
  echo "swiftc not found: building without the menu bar app (the CLI and daemon still work)"
fi

if [ "$OS" = darwin ]; then
  cp packaging/install.sh packaging/uninstall.sh packaging/panic.sh packaging/resume.sh LICENSE "$OUT/"
else
  cp packaging/linux/install.sh packaging/linux/uninstall.sh packaging/linux/panic.sh packaging/linux/resume.sh LICENSE "$OUT/"
fi
chmod 755 "$OUT"/*.sh

if [ "$OS" = darwin ]; then
  tar -C dist -czf "dist/$NAME.tar.gz" "$NAME"
else
  COPYFILE_DISABLE=1 tar -C dist -czf "dist/$NAME.tar.gz" "$NAME"
fi
( cd dist && shasum -a 256 netleash-*.tar.gz > SHA256SUMS )
echo "OK: dist/$NAME.tar.gz"
cat dist/SHA256SUMS
echo
echo "Install from this build:  cd dist/$NAME && sudo ./install.sh"
