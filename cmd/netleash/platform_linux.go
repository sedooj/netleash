// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

//go:build linux

package main

// Linux backend (experimental): the confined group is matched by nftables (`meta skgid`), the VPN is a tunnel
// interface named in the configuration, and the daemon runs as a systemd service.

import (
	"fmt"
	"net"
	"os"
	"os/user"
	"path"
	"sort"
	"strconv"
	"strings"

	"github.com/sedooj/netleash/internal/proc"
	"github.com/sedooj/netleash/internal/rules"
	"github.com/sedooj/netleash/internal/sys"
)

func nftBinary() string {
	for _, p := range []string{"/usr/sbin/nft", "/sbin/nft", "/usr/bin/nft"} {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

// lookupGID resolves the confined group's gid from the group database.
func (d *daemon) lookupGID() uint32 {
	g, err := user.LookupGroup(d.cfg.GroupName)
	if err != nil {
		return 0
	}
	n, err := strconv.ParseUint(g.Gid, 10, 32)
	if err != nil {
		return 0
	}
	return uint32(n)
}

// matchingInterfaces returns the up tunnel interfaces (with an address) whose names match one of the patterns.
func matchingInterfaces(patterns []string, ifs []net.Interface) []string {
	var out []string
	for _, i := range ifs {
		if i.Flags&net.FlagUp == 0 {
			continue
		}
		for _, p := range patterns {
			if ok, _ := path.Match(p, i.Name); ok {
				if addrs, _ := i.Addrs(); len(addrs) > 0 {
					out = append(out, i.Name)
				}
				break
			}
		}
	}
	sort.Strings(out)
	return out
}

// detectVPNInterface returns the configured tunnel interface that is up, or "".
func (d *daemon) detectVPNInterface(_ []proc.Proc) string {
	ifs, err := net.Interfaces()
	if err != nil {
		return ""
	}
	if found := matchingInterfaces(d.cfg.VPNInterfaces, ifs); len(found) > 0 {
		return found[0]
	}
	return ""
}

// learnVPNDNS is not needed on Linux: the VPN's DNS servers come from the configuration (vpnDnsServers).
func (d *daemon) learnVPNDNS(string) {}

// ensureMainRuleset only checks that nftables is usable; our table is independent of the rest of the ruleset.
func (d *daemon) ensureMainRuleset() bool {
	nft := nftBinary()
	if nft == "" {
		d.logf("nft not found: install nftables")
		return false
	}
	if out, ok := sys.Run(nft, "list", "tables"); !ok {
		d.logf("nft is not usable: %s", out)
		return false
	}
	return true
}

func (d *daemon) applyAnchor(iface string, dnsLock bool) bool {
	nft := nftBinary()
	if nft == "" {
		return false
	}
	text := rules.BuildNFT(rules.NFTParams{
		GID: d.gid.Load(), VPNIface: iface, VPNDNS: d.vpnDNSBlockList(), DNSLock: dnsLock,
		LoopbackBlockPorts: d.cfg.LoopbackBlockPorts,
	})
	if text == d.lastRules {
		// Verify that the kernel really holds our table (somebody may have run `nft flush ruleset`).
		if cur, ok := sys.Run(nft, "list", "table", rules.NFTTable); ok && strings.Contains(cur, "drop") {
			return true
		}
		d.logf("the nftables table was removed externally; restoring it")
	}
	if out, ok := sys.RunStdin(text, nft, "-f", "-"); !ok {
		d.logf("failed to load the nftables table: %s", out)
		return false
	}
	d.lastRules = text
	return true
}

// There is no menu bar app on Linux: events stay in the status file and the log.
func (d *daemon) menuAppRunning() bool { return false }

func (d *daemon) notifyFallback(title, text string) {}

// restartDaemon makes the service re-read its configuration.
func restartDaemon() error {
	if out, ok := sys.Run("/usr/bin/systemctl", "restart", "netleash.service"); !ok {
		return fmt.Errorf("%s", strings.TrimSpace(out))
	}
	return nil
}

// isPhysicalInterface is true for network cards (they have a backing device), false for tunnels, bridges, veth, lo.
func isPhysicalInterface(name string) bool {
	if name == "" || strings.ContainsAny(name, "/\x00") || name == "lo" {
		return false
	}
	_, err := os.Stat("/sys/class/net/" + name + "/device")
	return err == nil
}
