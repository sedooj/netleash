#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
#
# Builds the release layout into dist/netleash-darwin-<arch>/ and packs dist/netleash-darwin-<arch>.tar.gz.
# Requires Go and (for the menu bar app) Xcode or the Command Line Tools. No sudo needed.
#   ./build.sh                       local build:   0.1.0-dev+<commit>
#   NETLEASH_RELEASE=1 ./build.sh    release build: 0.1.0 (from the VERSION file)
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
case "$(uname -m)" in arm64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; *) echo "unsupported architecture"; exit 1 ;; esac
NAME="netleash-darwin-$ARCH"
OUT="dist/$NAME"
rm -rf dist && mkdir -p "$OUT"

echo "==> Netleash $VERSION ($ARCH)"
echo "==> Go binaries"
export CGO_ENABLED=0 GOOS=darwin GOARCH="$ARCH"
go test ./...
go build -trimpath -ldflags "-s -w -X main.version=$VERSION -X main.commit=$COMMIT -X main.date=$DATE" -o "$OUT/netleash" ./cmd/netleash
go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$OUT/netleash-exec" ./cmd/netleash-exec

echo "==> Spawn tool"
clang -O2 -Wall -o "$OUT/netleash-spawn" cmd/netleash-spawn/spawn.c

echo "==> Menu bar app"
if command -v swiftc >/dev/null; then
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

cp packaging/install.sh packaging/uninstall.sh packaging/panic.sh packaging/resume.sh LICENSE "$OUT/"
chmod 755 "$OUT"/*.sh

tar -C dist -czf "dist/$NAME.tar.gz" "$NAME"
( cd dist && shasum -a 256 "$NAME.tar.gz" > SHA256SUMS )
echo "OK: dist/$NAME.tar.gz"
cat dist/SHA256SUMS
echo
echo "Install from this build:  cd dist/$NAME && sudo ./install.sh"
