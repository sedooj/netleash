// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package proc

import "testing"

func TestParseStatusGID(t *testing.T) {
	gid, ok := parseStatusGID("Name:\tclaude\nUid:\t1000\t1000\t1000\t1000\nGid:\t1000\t990\t1000\t990\n")
	if !ok || gid != 990 {
		t.Fatalf("effective gid = %d, %v", gid, ok)
	}
	if _, ok := parseStatusGID("Name:\tx\n"); ok {
		t.Error("missing Gid line must not parse")
	}
}

func TestParseStartTimeWithAwkwardCommandName(t *testing.T) {
	// field 22 (starttime) is 4242; the command name contains spaces and a closing parenthesis
	stat := "123 (we) ird) S 1 123 123 0 -1 4194560 100 0 0 0 1 1 0 0 20 0 1 0 4242 1000 100 18446744073709551615"
	n, ok := parseStartTime(stat)
	if !ok || n != 4242 {
		t.Fatalf("start time = %d, %v", n, ok)
	}
}
