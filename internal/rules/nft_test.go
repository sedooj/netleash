// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package rules

import (
	"strings"
	"testing"
)

func nftLines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if strings.TrimSpace(l) != "" {
			out = append(out, strings.TrimSpace(l))
		}
	}
	return out
}

// The last rule of the chain must drop everything of the group, whatever the state.
func TestNFTAlwaysEndsWithGroupDrop(t *testing.T) {
	for _, p := range []NFTParams{
		{GID: 990},
		{GID: 990, VPNIface: "wg0", VPNDNS: []string{"10.8.1.1"}, LoopbackBlockPorts: []int{7890}},
		{GID: 990, DNSLock: true, VPNDNS: []string{"10.8.1.1"}},
	} {
		l := nftLines(BuildNFT(p))
		if got := l[len(l)-3]; got != "meta skgid 990 drop" {
			t.Errorf("last rule = %q for %+v", got, p)
		}
	}
}

// The only accept rules are loopback and the live tunnel; nothing else may be allowed for the group.
func TestNFTOnlyLoopbackAndTunnelAreAccepted(t *testing.T) {
	out := BuildNFT(NFTParams{GID: 990, VPNIface: "amn0", DNSLock: true})
	var accepts []string
	for _, l := range nftLines(out) {
		if strings.HasSuffix(l, " accept") {
			accepts = append(accepts, l)
		}
	}
	want := []string{`meta skgid 990 oifname "lo" accept`, `meta skgid 990 oifname "amn0" accept`}
	if len(accepts) != 2 || accepts[0] != want[0] || accepts[1] != want[1] {
		t.Fatalf("accept rules = %q", accepts)
	}
	if strings.Contains(BuildNFT(NFTParams{GID: 990}), "amn0") {
		t.Error("no tunnel rule may exist while the VPN is down")
	}
}

func TestNFTDNSRules(t *testing.T) {
	up := BuildNFT(NFTParams{GID: 1, VPNIface: "wg0", VPNDNS: []string{"10.0.0.1", "10.0.0.2"}})
	if !strings.Contains(up, `oifname != { "lo", "wg0" } ip daddr { 10.0.0.1, 10.0.0.2 } meta l4proto { tcp, udp } th dport 53 drop`) {
		t.Errorf("VPN DNS must not leave through other interfaces:\n%s", up)
	}
	if strings.Contains(up, "853") {
		t.Error("DNS lock must be off while the VPN is up")
	}
	down := BuildNFT(NFTParams{GID: 1, DNSLock: true})
	if !strings.Contains(down, `oifname != "lo" meta l4proto { tcp, udp } th dport { 53, 853 } drop`) {
		t.Errorf("DNS lock missing:\n%s", down)
	}
}

func TestNFTReplacesTableAtomically(t *testing.T) {
	l := nftLines(BuildNFT(NFTParams{GID: 5}))
	if l[0] != "table inet netleash" || l[1] != "delete table inet netleash" || !strings.HasPrefix(l[2], "table inet netleash {") {
		t.Errorf("must create, delete and redefine the table in one script: %q", l[:3])
	}
}
