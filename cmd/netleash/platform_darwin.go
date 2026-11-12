// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

//go:build darwin

package main

// macOS backend: groups from Directory Services, VPN detection through AmneziaVPN's process arguments, the pf anchor,
// and notifications through the menu bar app.

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"github.com/sedooj/netleash/internal/config"
	"github.com/sedooj/netleash/internal/netinfo"
	"github.com/sedooj/netleash/internal/proc"
	"github.com/sedooj/netleash/internal/rules"
	"github.com/sedooj/netleash/internal/sys"
)

// ---- group ----

// lookupGID resolves the confined group's gid through Directory Services (macOS groups are not in /etc/group).
func (d *daemon) lookupGID() uint32 {
	out, ok := sys.Run("/usr/bin/dscl", ".", "-read", "/Groups/"+d.cfg.GroupName, "PrimaryGroupID")
	if !ok {
		return 0
	}
	f := strings.Fields(out)
	if len(f) == 2 && f[0] == "PrimaryGroupID:" {
		if n, err := strconv.ParseUint(f[1], 10, 32); err == nil {
			return uint32(n)
		}
	}
	return 0
}

// ---- VPN detection ----

// detectVPNInterface returns the utun interface of the live VPN, or "".
func (d *daemon) detectVPNInterface(procs []proc.Proc) string {
	seen := map[string]bool{}
	var candidates []string
	for _, p := range procs {
		if !strings.HasPrefix(p.Path, d.cfg.VPNAppPath+"/") {
			continue
		}
		_, args := proc.Args(p.PID)
		for _, n := range netinfo.UtunNames(strings.Join(args, " ")) {
			if !seen[n] {
				seen[n] = true
				candidates = append(candidates, n)
			}
		}
	}
	if len(candidates) == 0 {
		return ""
	}
	sort.Strings(candidates)
	routes, _ := sys.Run("/usr/sbin/netstat", "-rn", "-f", "inet")
	for _, c := range candidates {
		ifc, _ := sys.Run("/sbin/ifconfig", c)
		if netinfo.InterfaceIsUp(ifc) && netinfo.HasDefaultRoute(routes, c) {
			return c
		}
	}
	return ""
}

func physicalInterfaces() []string {
	out, _ := sys.Run("/sbin/ifconfig", "-l")
	return netinfo.PhysicalInterfaces(out)
}

// learnVPNDNS finds the VPN's DNS servers: addresses from `scutil --dns` that have a host route via the VPN interface.
func (d *daemon) learnVPNDNS(iface string) {
	if !d.cfg.AutoDetectVPNDNS {
		return
	}
	scutil, _ := sys.Run("/usr/sbin/scutil", "--dns")
	routes, _ := sys.Run("/usr/sbin/netstat", "-rn", "-f", "inet")
	var subnets []netipPrefix
	for _, i := range physicalInterfaces() {
		out, _ := sys.Run("/sbin/ifconfig", i)
		subnets = append(subnets, netinfo.Subnets(out)...)
	}
	found := netinfo.FilterVPNDNS(netinfo.Nameservers(scutil), netinfo.HostRoutesVia(routes, iface), subnets)
	var added []string
	for _, s := range found {
		if !d.learned[s] {
			d.learned[s] = true
			added = append(added, s)
		}
	}
	if len(added) == 0 {
		return
	}
	var all []string
	for s := range d.learned {
		all = append(all, s)
	}
	sort.Strings(all)
	if data, err := json.Marshal(all); err == nil {
		_ = os.WriteFile(config.LearnedDNSPath, data, 0o644)
	}
	d.logf("detected VPN DNS servers: %s", strings.Join(added, ", "))
}

// ---- pf ----

// ensureMainRuleset makes sure pf is enabled and the main ruleset contains `anchor "com.apple/*"`, through
// which our anchor runs.
func (d *daemon) ensureMainRuleset() bool {
	info, _ := sys.Run("/sbin/pfctl", "-si")
	main, _ := sys.Run("/sbin/pfctl", "-sr")
	enabled := strings.Contains(info, "Status: Enabled")
	hooked := false
	for _, l := range strings.Split(main, "\n") {
		if strings.HasPrefix(l, `anchor "com.apple/*"`) {
			hooked = true
		}
	}
	if enabled && hooked {
		return true
	}
	d.logf("pf was changed externally (enabled: %v, anchor com.apple/*: %v); main ruleset:\n%s", enabled, hooked, main)
	// Restore Apple's stock ruleset, which contains anchor "com.apple/*".
	if out, ok := sys.Run("/sbin/pfctl", "-f", "/etc/pf.conf"); !ok {
		d.logf("pfctl -f failed: %s", out)
		return false
	}
	if !enabled {
		out, _ := sys.Run("/sbin/pfctl", "-E")
		if i := strings.Index(out, "Token : "); i >= 0 {
			if f := strings.Fields(out[i+len("Token : "):]); len(f) > 0 {
				_ = os.WriteFile(config.PFTokenPath, []byte(f[0]), 0o600)
			}
		}
	}
	d.lastRules = ""
	d.logf("main pf ruleset restored")
	return true
}

func (d *daemon) applyAnchor(iface string, dnsLock bool) bool {
	text := rules.Build(rules.Params{
		Group: d.cfg.GroupName, VPNIface: iface, PhysicalIfaces: physicalInterfaces(),
		VPNDNS: d.vpnDNSBlockList(), DNSLock: dnsLock, LoopbackBlockPorts: d.cfg.LoopbackBlockPorts,
	})
	if text == d.lastRules {
		// Verify that the kernel really holds our rules.
		if cur, _ := sys.Run("/sbin/pfctl", "-a", config.AnchorName, "-sr"); strings.Contains(cur, "block drop quick proto") {
			return true
		}
	}
	if out, ok := sys.RunStdin(text, "/sbin/pfctl", "-a", config.AnchorName, "-f", "-"); !ok {
		d.logf("failed to load anchor: %s", out)
		return false
	}
	d.lastRules = text
	return true
}

func (d *daemon) menuAppRunning() bool {
	procs, err := proc.List()
	if err != nil {
		return false
	}
	for _, p := range procs {
		if strings.Contains(p.Path, "/Netleash.app/Contents/MacOS/") {
			return true
		}
	}
	return false
}

// notifyFallback is used only when the menu bar app is not running (it would be silent otherwise). macOS shows such
// notifications under the generic "Script Editor" name, which is why the app path is preferred.
func (d *daemon) notifyFallback(title, text string) {
	fi, err := os.Stat("/dev/console")
	if err != nil {
		return
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok || st.Uid == 0 {
		return
	}
	esc := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	script := fmt.Sprintf(`display notification "%s" with title "%s"`, esc.Replace(text), esc.Replace(title))
	go sys.Run("/bin/launchctl", "asuser", strconv.Itoa(int(st.Uid)), "/usr/bin/osascript", "-e", script)
}

// restartDaemon makes launchd restart the daemon (the pf anchor stays in the kernel meanwhile).
func restartDaemon() error {
	if out, err := exec.Command("/bin/launchctl", "kickstart", "-k", "system/"+config.DaemonLabel).CombinedOutput(); err != nil {
		return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

func isPhysicalInterface(name string) bool { return netinfo.IsPhysicalInterface(name) }
