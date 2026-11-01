#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
# Install / update:  ./build.sh && sudo ./install.sh
# Read the README (limitations, disclaimer) before installing: this installs a root daemon and a setuid helper.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run: sudo ./install.sh"; exit 1; }
[ -x build/netleashd ] && [ -x build/netleash-exec ] && [ -x build/Netleash ] || { echo "Run ./build.sh first"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_UID=$(id -u "$USER_NAME")
N=netleash
L=/usr/local/libexec/$N
LABEL=org.netleash.daemon
AGENT_LABEL=org.netleash.app
GROUP=_netleash

echo "This will install a root daemon and a setuid helper (see README: Disclaimer, Limitations)."
echo "Requirements: Claude.app and AmneziaVPN with its Kill Switch turned OFF."
echo "After installation, any Claude.app started outside Netleash is terminated immediately."
echo "Save your work and quit Claude first (including a Claude Code session running inside it)."
read -r -p "Continue? [y/N] " a; [ "$a" = y ] || exit 1

# 1. Group
if ! dscl . -read /Groups/$GROUP >/dev/null 2>&1; then
  for g in $(seq 350 399); do
    dscl . -search /Groups PrimaryGroupID $g | grep -q . || { dseditgroup -o create -i $g $GROUP; break; }
  done
fi
dscl . -read /Groups/$GROUP PrimaryGroupID

# 2. Files
mkdir -p $L /usr/local/etc/$N /usr/local/bin
install -o root -g wheel -m 755 build/netleashd $L/netleashd
install -o root -g wheel -m 4755 build/netleash-exec $L/netleash-exec
install -o root -g wheel -m 755 scripts/panic.sh $L/panic.sh
install -o root -g wheel -m 755 scripts/resume.sh $L/resume.sh
install -o root -g wheel -m 755 scripts/netleash /usr/local/bin/netleash
[ -f /usr/local/etc/$N/config.json ] || echo '{}' > /usr/local/etc/$N/config.json
chown root:wheel /usr/local/etc/$N/config.json; chmod 644 /usr/local/etc/$N/config.json
codesign -f -s - $L/netleashd $L/netleash-exec 2>/dev/null || true
chmod 4755 $L/netleash-exec   # codesign must not strip the setuid bit

# 3. Daemon (starts at boot)
launchctl enable system/$LABEL 2>/dev/null || true
cat > /Library/LaunchDaemons/$LABEL.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>$LABEL</string>
 <key>ProgramArguments</key><array><string>$L/netleashd</string></array>
 <key>RunAtLoad</key><true/>
 <key>KeepAlive</key><true/>
 <key>StandardOutPath</key><string>/var/log/$N.log</string>
 <key>StandardErrorPath</key><string>/var/log/$N.log</string>
</dict></plist>
P
chown root:wheel /Library/LaunchDaemons/$LABEL.plist; chmod 644 /Library/LaunchDaemons/$LABEL.plist
launchctl bootout system/$LABEL 2>/dev/null || true
# bootout is asynchronous: wait until the old daemon is really unloaded, otherwise bootstrap fails with "Input/output error"
for _ in $(seq 1 50); do launchctl print system/$LABEL >/dev/null 2>&1 || break; sleep 0.2; done
ok=0
for _ in $(seq 1 10); do
  if launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist 2>/dev/null; then ok=1; break; fi
  launchctl print system/$LABEL >/dev/null 2>&1 && { ok=1; break; }   # already loaded
  sleep 1
done
[ "$ok" = 1 ] || { echo "Could not start the daemon. Log: /var/log/$N.log"; exit 1; }
launchctl kickstart system/$LABEL 2>/dev/null || true

# 4. The app: launcher + menu bar icon + leak test + rollback
launchctl asuser "$USER_UID" launchctl bootout "gui/$USER_UID/$AGENT_LABEL" 2>/dev/null || true
pkill -u "$USER_UID" -f "Netleash.*Contents/MacOS" 2>/dev/null || true
APP="/Applications/Netleash.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 build/Netleash "$APP/Contents/MacOS/Netleash"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleName</key><string>Netleash</string>
 <key>CFBundleDisplayName</key><string>Netleash</string>
 <key>CFBundleIdentifier</key><string>$AGENT_LABEL</string>
 <key>CFBundleExecutable</key><string>Netleash</string>
 <key>CFBundleIconFile</key><string>icon.icns</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>1.0</string>
 <key>LSUIElement</key><true/>
 <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
P
# The icon is copied from the user's own Claude.app at install time; no third-party artwork is shipped in this repository.
cp /Applications/Claude.app/Contents/Resources/electron.icns "$APP/Contents/Resources/icon.icns" 2>/dev/null || true
codesign -f -s - "$APP" 2>/dev/null || true
chown -R "$USER_NAME" "$APP"

# Start the icon at login (can be switched off in the app's menu)
AGENT="/Users/$USER_NAME/Library/LaunchAgents/$AGENT_LABEL.plist"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>$AGENT_LABEL</string>
 <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Netleash</string><string>--background</string></array>
 <key>RunAtLoad</key><true/>
</dict></plist>
P
chown "$USER_NAME" "$AGENT"
launchctl asuser "$USER_UID" launchctl bootstrap "gui/$USER_UID" "$AGENT" 2>/dev/null || echo "(the menu bar icon will appear at your next login)"

sleep 2
echo; netleash status || true
echo "Done. Open “Netleash” from /Applications (or the menu bar icon → Open Claude)."
