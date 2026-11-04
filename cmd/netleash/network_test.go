// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package main

import "testing"

func TestNetworkTestDoesNotPassWithoutEvidence(t *testing.T) {
	for _, tc := range []struct {
		name             string
		leak             bool
		tested           int
		vpnUp, vpnWorked bool
		code             int
	}{
		{"no interfaces", false, 0, true, true, 2},
		{"offline without VPN", false, 0, false, false, 2},
		{"VPN not responding", false, 1, true, false, 2},
		{"direct connection escaped", true, 1, true, false, 1},
		{"VPN works and direct blocked", false, 1, true, true, 0},
		{"VPN off and direct blocked", false, 1, false, false, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := networkTestResult(tc.leak, tc.tested, tc.vpnUp, tc.vpnWorked); got != tc.code {
				t.Fatalf("got %d, want %d", got, tc.code)
			}
		})
	}
}
