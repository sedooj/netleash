#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
#
# Installs / updates Netleash from the directory this script lives in (a release archive or dist/ after ./build.sh):
#   sudo ./install.sh            (add -y or NETLEASH_YES=1 to skip the confirmation)
# This installs a root daemon and a setuid helper. Read the README (Disclaimer, Limitations) first.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo ./install.sh"; exit 1; }
# The installer closes and restarts apps, possibly including the one that started it: it must not die with its caller.
trap '' HUP PIPE
# Not on a terminal (started by the menu bar app, over a pipe, ...): log to a file instead of a pipe that may disappear.
if [ ! -t 1 ]; then exec >>/var/log/netleash-install.log 2>&1; echo "--- $(date) install.sh started"; fi
cd "$(dirname "$0")"
[ -x netleash ] && [ -x netleash-exec ] && [ -x netleash-spawn ] || { echo "netleash binaries not found next to install.sh"; exit 1; }

USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_UID=$(id -u "$USER_NAME")
N=netleash
L=/usr/local/libexec/$N
LABEL=org.netleash.daemon
AGENT_LABEL=org.netleash.app
GROUP=_netleash

PROTECTED_APPS=()
if [ -f /usr/local/etc/$N/config.json ]; then
  while IFS= read -r app; do
    [ -z "$app" ] || PROTECTED_APPS+=("$app")
  done < <(./netleash apps paths)
fi

# PIDs of the protected app (the Squirrel updater is not part of it)
app_pids() {
  # Compare literal executable prefixes, not regular expressions supplied by app paths.
  ps -axww -o pid=,comm= | while read -r p executable; do
    case "$executable" in
      "$PROTECTED_APP"/Contents/*) case "$executable" in *Squirrel.framework*) ;; *) echo "$p" ;; esac ;;
    esac
  done
}
# Is this installer itself running inside the protected app (e.g. in a terminal of Claude Code)? Then closing it would
# end the installer too, so it is left open: the update does not require closing it.
inside_protected_app() {
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    case "$(ps -o command= -p "$p" 2>/dev/null)" in *"$PROTECTED_APP/Contents/"*) return 0 ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}
# Quits the protected app (gracefully first, then by force). Returns 0 if it had to be closed.
close_protected_app() {
  [ -n "$(app_pids)" ] || return 1
  if inside_protected_app; then
    echo "The installer is running inside $APP_NAME: leaving it open (it is not required to close it)."
    return 1
  fi
  echo "Closing $APP_NAME ..."
  launchctl asuser "$USER_UID" sudo -u "$USER_NAME" /usr/bin/osascript -e 'on run argv' -e 'tell application (item 1 of argv) to quit' -e 'end run' "$PROTECTED_APP" >/dev/null 2>&1 || true
  for _ in $(seq 1 "${NETLEASH_CLOSE_WAIT:-25}"); do [ -z "$(app_pids)" ] && return 0; sleep 0.4; done
  app_pids | xargs kill -9 2>/dev/null || true
  sleep 0.5
  return 0
}
[ "${NETLEASH_SOURCE_ONLY:-}" = "1" ] && return 0 2>/dev/null

echo "Netleash $(./netleash version | awk '{print $2}')"
echo "This installs a root daemon and a setuid helper (see README: Disclaimer, Limitations)."
echo "VPN: AmneziaVPN with its Kill Switch turned OFF. Other VPN providers are not validated."
echo "Configured protected apps:"
for app in ${PROTECTED_APPS[@]+"${PROTECTED_APPS[@]}"}; do echo "  $app"; done
echo "Running protected apps are closed and reopened under protection. Save your work first."
if [ "${1:-}" != "-y" ] && [ "${NETLEASH_YES:-}" != "1" ]; then
  read -r -p "Continue? [y/N] " a || a=n
  [ "$a" = y ] || { echo "Aborted."; exit 1; }
fi
# keep going if the terminal disappears while the app (and with it possibly the terminal's window) is being closed
trap '' HUP

REOPEN_APPS=()
for PROTECTED_APP in ${PROTECTED_APPS[@]+"${PROTECTED_APPS[@]}"}; do
  APP_NAME="$(basename "$PROTECTED_APP" .app)"
  if close_protected_app; then REOPEN_APPS+=("$PROTECTED_APP"); fi
done

# 1. Group
if ! dscl . -read /Groups/$GROUP >/dev/null 2>&1; then
  for g in $(seq 350 399); do
    dscl . -search /Groups PrimaryGroupID $g | grep -q . || { dseditgroup -o create -i $g $GROUP; break; }
  done
fi
dscl . -read /Groups/$GROUP PrimaryGroupID

# 2. Files
mkdir -p $L /usr/local/etc/$N /usr/local/bin
install -o root -g wheel -m 755 netleash $L/netleash
install -o root -g wheel -m 4755 netleash-exec $L/netleash-exec
install -o root -g wheel -m 755 netleash-spawn $L/netleash-spawn
install -o root -g wheel -m 755 panic.sh $L/panic.sh
install -o root -g wheel -m 755 resume.sh $L/resume.sh
install -o root -g wheel -m 755 uninstall.sh $L/uninstall.sh
rm -f $L/netleashd                       # binary of the pre-Go versions
ln -sf $L/netleash /usr/local/bin/netleash
[ -f /usr/local/etc/$N/config.json ] || echo '{"protectedApps":[]}' > /usr/local/etc/$N/config.json
chown root:wheel /usr/local/etc/$N/config.json; chmod 644 /usr/local/etc/$N/config.json
codesign -f -s - $L/netleash $L/netleash-exec $L/netleash-spawn 2>/dev/null || true
chmod 4755 $L/netleash-exec               # codesign must not strip the setuid bit

# 3. Daemon (starts at boot)
launchctl enable system/$LABEL 2>/dev/null || true
cat > /Library/LaunchDaemons/$LABEL.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>$LABEL</string>
 <key>ProgramArguments</key><array><string>$L/netleash</string><string>daemon</string></array>
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
if [ -d Netleash.app ]; then
  launchctl asuser "$USER_UID" launchctl bootout "gui/$USER_UID/$AGENT_LABEL" 2>/dev/null || true
  pkill -u "$USER_UID" -f "Netleash.app/Contents/MacOS" 2>/dev/null || true
  APP="/Applications/Netleash.app"
  rm -rf "$APP"; cp -R Netleash.app "$APP"
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
 <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>$APP</string><string>--args</string><string>--background</string></array>
 <key>RunAtLoad</key><true/>
</dict></plist>
P
  # "open" starts the app through LaunchServices, which macOS requires for the app to be registered for notifications
  chown "$USER_NAME" "$AGENT"
  launchctl asuser "$USER_UID" launchctl bootstrap "gui/$USER_UID" "$AGENT" 2>/dev/null || echo "(the menu bar icon will appear at your next login)"
else
  echo "No menu bar app in this build: use the CLI (netleash status/test/run)."
fi

sleep 2
echo; netleash status || true
# `netleash update` unpacks the archive into a temporary directory of its own: remove it when done
case "$PWD" in */netleash-update-*/netleash-darwin-*|*/netleash-install-*/netleash-darwin-*) U="$(dirname "$PWD")"; cd /; rm -rf "$U" ;; esac
if [ -n "${REOPEN_APPS[*]-}" ]; then
  for _ in $(seq 1 30); do netleash status >/dev/null 2>&1 && break; sleep 0.5; done
  for app in ${REOPEN_APPS[@]+"${REOPEN_APPS[@]}"}; do
    echo "Reopening $(basename "$app" .app) through Netleash ..."
    launchctl asuser "$USER_UID" sudo -u "$USER_NAME" "$L/netleash" apps launch "$app" </dev/null >>/var/log/netleash-launch.log 2>&1 &
  done
fi
if [ -d /Applications/Netleash.app ]; then
  launchctl asuser "$USER_UID" sudo -u "$USER_NAME" /usr/bin/open -a /Applications/Netleash.app || true
fi
echo "Done. Open Netleash to manage apps, or use the menu bar icon → Applications to launch them. Check: netleash test"
