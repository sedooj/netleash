// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

//go:build linux

package main

import (
	"net"
	"testing"
)

func TestMatchingInterfaces(t *testing.T) {
	up := net.FlagUp | net.FlagPointToPoint
	ifs := []net.Interface{
		{Name: "eth0", Flags: net.FlagUp},
		{Name: "wg1", Flags: up},
		{Name: "wg0", Flags: up},
		{Name: "amn0", Flags: net.FlagPointToPoint}, // down
	}
	// interfaces without addresses are never selected: the test machine's wg0/wg1 do not exist, so only the
	// pattern and flag handling is checked here
	if got := matchingInterfaces([]string{"nomatch*"}, ifs); len(got) != 0 {
		t.Errorf("got %v", got)
	}
	if got := matchingInterfaces([]string{"amn0"}, ifs); len(got) != 0 {
		t.Errorf("a down interface must not match: %v", got)
	}
}
