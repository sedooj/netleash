#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Netleash contributors
#
# End-to-end test of the Linux build, run INSIDE a privileged container (see run.sh): installs the release archive,
# protects a program, and checks with the real kernel (nftables) that the program is confined, that a vanishing VPN
# interface cuts it off, that unprotected launches die, and that panic/resume/uninstall work.
set -u
ARCHIVE="${1:?usage: e2e.sh <netleash-linux-ARCH.tar.gz>}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
check(){ local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
as_user() { sudo -u tester env "PATH=/home/tester/.local/bin:$PATH" "$@"; }

echo "== setup"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq nftables iproute2 sudo curl procps ca-certificates python3-minimal >/dev/null 2>&1 || { echo "cannot install packages"; exit 2; }
useradd -m -s /bin/bash tester 2>/dev/null
echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester
# There is no systemd in the container: a stub starts and stops the daemon the way the unit would.
cat > /usr/bin/systemctl <<'S'
#!/bin/bash
start() { pkill -f 'netleash daemon' 2>/dev/null; sleep 0.3; setsid /usr/local/libexec/netleash/netleash daemon >>/var/log/netleash.log 2>&1 < /dev/null & }
case "$1" in
  restart) start ;;
  enable) [ "${2:-}" = "--now" ] && start ;;
  disable) [ "${2:-}" = "--now" ] && pkill -f 'netleash daemon' ;;
esac
exit 0
S
chmod 755 /usr/bin/systemctl
mkdir -p /etc/systemd/system

# A fake VPN: interface amn0 whose far end lives in the network namespace "vpnns" together with a small web server.
# Reaching 10.9.0.1 therefore works only when packets really leave through amn0.
ip netns add vpnns 2>/dev/null; ip netns exec vpnns ip link set lo up
vpn_up() {
  ip link add amn0 type veth peer name amn0p && ip link set amn0p netns vpnns || return 1
  ip addr add 10.9.0.2/24 dev amn0; ip link set amn0 up
  ip netns exec vpnns ip addr add 10.9.0.1/24 dev amn0p; ip netns exec vpnns ip link set amn0p up
  pkill -f 'http.server 80' 2>/dev/null
  ip netns exec vpnns python3 -m http.server 80 --bind 10.9.0.1 >/dev/null 2>&1 &
  sleep 1
}
vpn_down() { ip link del amn0 2>/dev/null; }
# A dropped TCP SYN is retransmitted until curl's timeout, so "blocked" shows up as a failed connection (exit != 0)
# while "allowed" must actually deliver the page.
works()  { as_user netleash run claude -s -m 3 http://10.9.0.1/ | grep -q Directory; }

if ! timeout 8 curl -s -o /dev/null -m 6 http://1.1.1.1; then echo "no internet in the container: cannot run the leak checks"; exit 2; fi

echo "== install"
tmp=$(mktemp -d); tar -xzf "$ARCHIVE" -C "$tmp"; d=$(ls -d "$tmp"/netleash-linux-*)
"$d/install.sh" -y >/tmp/install.log 2>&1; check "installer succeeds" test $? -eq 0
check "setuid helper installed" test -u /usr/local/libexec/netleash/netleash-exec
check "group exists" getent group netleash
sleep 2
check "daemon armed, VPN down, nothing protected yet" bash -c 'netleash status | grep -q "VPN disconnected"'
check "nftables table exists" nft list table inet netleash
check "version prints" bash -c 'netleash version | grep -q "^netleash "'

echo "== command-line profile"
mkdir -p /home/tester/.local/share/claude/versions /home/tester/.local/bin
cp /usr/bin/curl /home/tester/.local/share/claude/versions/1.0.0
ln -s /home/tester/.local/share/claude/versions/1.0.0 /home/tester/.local/bin/claude
chown -R tester /home/tester/.local
as_user netleash apps add-cli claude >/tmp/add.log 2>&1; check "add-cli claude works" test $? -eq 0
check "whole install directory is protected (updates stay protected)" grep -q '/home/tester/.local/share/claude' /usr/local/etc/netleash/config.json
check "profile has kind cli" grep -q '"kind": "cli"' /usr/local/etc/netleash/config.json
sleep 2
check "daemon applied the profile" bash -c 'netleash status | grep -q ".local/share/claude"'
check "/bin/sh is refused" bash -c '! netleash apps add-cli /bin/sh 2>/dev/null; ! sudo netleash apps add-cli /bin/sh 2>/dev/null'
check "a shared directory is refused" bash -c '! sudo netleash apps add-cli /usr/local/bin 2>/dev/null'

echo "== VPN down: kernel blocks the program, other programs are untouched"
as_user netleash run claude -s -m 3 -o /dev/null http://1.1.1.1; rc=$?
check "confined claude cannot reach the internet" test $rc -ne 0
as_user curl -s -m 5 -o /dev/null http://1.1.1.1; check "unconfined curl still works" test $? -eq 0
check "confined groups are the only one" bash -c '[ "$(sudo -u tester netleash run id -G)" = "$(getent group netleash | cut -d: -f3)" ]'
check "user id is kept" bash -c '[ "$(sudo -u tester netleash run id -u)" = "$(id -u tester)" ]'

echo "== VPN up"
vpn_up
sleep 2
check "status shows the VPN" bash -c 'netleash status | grep -q "VPN connected (amn0)"'
check "table allows amn0 only" bash -c 'nft list table inet netleash | grep -q "oifname \"amn0\" accept"'
check "confined claude reaches the server behind the tunnel" works
as_user netleash run claude -s -m 3 --interface eth0 -o /dev/null http://1.1.1.1; check "forced through eth0 is blocked" test $? -ne 0
as_user netleash run claude -s -m 3 -o /dev/null http://1.1.1.1; check "internet over the physical route is blocked even with the VPN up" test $? -ne 0

echo "== VPN disappears"
as_user netleash run sleep 60 & keeper=$!
sleep 1
vpn_down
as_user netleash run claude -s -m 3 -o /dev/null http://1.1.1.1; check "blocked immediately after the interface is gone" test $? -ne 0
sleep 3
check "daemon reports VPN down" bash -c 'netleash status | grep -q "VPN disconnected"'
check "DNS lock is on while a confined process runs" bash -c 'nft list table inet netleash | grep -q "853"'
kill $keeper 2>/dev/null; pkill -u tester sleep; sleep 2
check "DNS lock is released when nothing confined is running" bash -c '! nft list table inet netleash | grep -q "853"'

echo "== VPN returns"
vpn_up
sleep 2
check "reconnected without restarting anything" bash -c 'netleash status | grep -q "VPN connected (amn0)"'
check "traffic flows through the tunnel again" works

echo "== launcher enforcement"
# The target never answers (the SYN is dropped), so the program is still running when the daemon's scan finds it:
# a fast real server could finish within the ~50 ms before the scan and hide the check.
as_user bash -c 'claude -s -m 20 -o /dev/null http://10.255.255.1/ & wait $!'; rc=$?
check "claude started outside Netleash is killed (SIGKILL)" test $rc -eq 137
check "the daemon logged it" grep -q "unprotected launch" /var/log/netleash.log

echo "== somebody flushes the ruleset"
nft flush ruleset; sleep 2
check "the table is restored" nft list table inet netleash
as_user netleash run claude -s -m 3 -o /dev/null http://1.1.1.1; check "still blocked after the restore" test $? -ne 0
check "and still allowed through the tunnel" works

echo "== panic and resume"
netleash panic >/tmp/panic.log 2>&1 </dev/null || /usr/local/libexec/netleash/panic.sh >/tmp/panic.log 2>&1
check "panic removes the table" bash -c '! nft list table inet netleash 2>/dev/null'
/usr/local/libexec/netleash/resume.sh >/tmp/resume.log 2>&1; sleep 3
check "resume restores it" nft list table inet netleash

echo "== uninstall"
/usr/local/libexec/netleash/uninstall.sh >/tmp/uninstall.log 2>&1
check "files removed" bash -c '[ ! -e /usr/local/libexec/netleash ] && [ ! -e /usr/local/bin/netleash ]'
check "table removed" bash -c '! nft list table inet netleash 2>/dev/null'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
