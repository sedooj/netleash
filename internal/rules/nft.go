// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package rules

import (
	"fmt"
	"strconv"
	"strings"
)

// NFTTable is the nftables table that holds the Linux ruleset.
const NFTTable = "inet netleash"

// NFTParams describes the desired state of the Linux ruleset.
type NFTParams struct {
	GID                uint32   // confined group id
	VPNIface           string   // live tunnel interface, "" when the VPN is down
	VPNDNS             []string // VPN DNS servers that may never be queried through a non-VPN interface
	DNSLock            bool     // block all DNS leaving the machine (VPN down and a confined process running)
	LoopbackBlockPorts []int    // local proxy ports the confined group must not reach
}

func quoted(items ...string) string {
	q := make([]string, len(items))
	for i, s := range items {
		q[i] = strconv.Quote(s)
	}
	return "{ " + strings.Join(q, ", ") + " }"
}

// BuildNFT returns an nft script that atomically replaces the whole table (one transaction).
//
// The same invariants as the pf anchor hold (and are tested): the last rule always drops everything of the group, and
// the only accept rules for the group are loopback and the live VPN interface. `oifname` compares names as strings, so
// the accept rule stops matching the moment the interface disappears and the kernel drops the traffic with no
// daemon involved.
func BuildNFT(p NFTParams) string {
	var b strings.Builder
	fmt.Fprintf(&b, "table %s\ndelete table %s\n", NFTTable, NFTTable)
	fmt.Fprintf(&b, "table %s {\n  chain output {\n    type filter hook output priority -10; policy accept;\n", NFTTable)
	// DNS is resolved by a service outside the group (systemd-resolved, nscd, ...), so these rules apply to everyone.
	notVPN := `oifname != "lo"`
	if p.VPNIface != "" {
		notVPN = "oifname != " + quoted("lo", p.VPNIface)
	}
	if len(p.VPNDNS) > 0 {
		fmt.Fprintf(&b, "    %s ip daddr { %s } meta l4proto { tcp, udp } th dport 53 drop\n", notVPN, strings.Join(p.VPNDNS, ", "))
	}
	if p.DNSLock {
		fmt.Fprintf(&b, "    oifname != \"lo\" meta l4proto { tcp, udp } th dport { 53, 853 } drop\n")
	}
	g := fmt.Sprintf("meta skgid %d", p.GID)
	if len(p.LoopbackBlockPorts) > 0 {
		ports := make([]string, len(p.LoopbackBlockPorts))
		for i, port := range p.LoopbackBlockPorts {
			ports[i] = strconv.Itoa(port)
		}
		fmt.Fprintf(&b, "    %s oifname \"lo\" meta l4proto { tcp, udp } th dport { %s } drop\n", g, strings.Join(ports, ", "))
	}
	fmt.Fprintf(&b, "    %s oifname \"lo\" accept\n", g)
	if p.VPNIface != "" {
		fmt.Fprintf(&b, "    %s oifname %s accept\n", g, strconv.Quote(p.VPNIface))
	}
	fmt.Fprintf(&b, "    %s drop\n  }\n}\n", g)
	return b.String()
}
