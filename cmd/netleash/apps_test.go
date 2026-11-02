// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/sedooj/netleash/internal/config"
	"github.com/sedooj/netleash/internal/proc"
)

func TestAppExecutableStaysInsideBundle(t *testing.T) {
	app := filepath.Join(t.TempDir(), "App's test.app")
	dir := filepath.Join(app, "Contents", "MacOS")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	plist := filepath.Join(app, "Contents", "Info.plist")
	for _, name := range []string{"../outside", "", ".", "..", "Main"} {
		data := `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>` + name + `</string></dict></plist>`
		if err := os.WriteFile(plist, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := appExecutable(app); err == nil {
			t.Fatalf("accepted missing/unsafe executable %q", name)
		}
	}
	binary := filepath.Join(dir, "Main")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, err := appExecutable(app); err != nil || got != binary {
		t.Fatalf("valid bundle: %q, %v", got, err)
	}
	if err := os.Remove(binary); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/bin/sh", binary); err != nil {
		t.Fatal(err)
	}
	if _, err := appExecutable(app); err == nil {
		t.Fatal("accepted executable symlink outside bundle")
	}
}

func TestDaemonProtectsMultipleBundles(t *testing.T) {
	d := daemon{cfg: config.Default()}
	d.cfg.ProtectedApps = []config.ProtectedApp{{Path: "/Applications/Claude.app", Enabled: true}, {Path: "/Applications/Codex.app", Enabled: true}, {Path: "/Applications/Off.app", Enabled: false}}
	for path, want := range map[string]bool{
		"/Applications/Claude.app/Contents/MacOS/Claude": true,
		"/Applications/Codex.app/Contents/MacOS/Codex":   true,
		"/Applications/Off.app/Contents/MacOS/Off":       false,
		"/Applications/Codex.app2/Contents/MacOS/Codex":  false,
	} {
		if got := d.inProtectedApp(proc.Proc{Path: path}); got != want {
			t.Errorf("%s: got %v", path, got)
		}
	}
}

func TestDNSLockSurvivesParentAppExit(t *testing.T) {
	// The app bundle is gone, but its spawned command must still keep system DNS locked when VPN is down.
	ps := []proc.Proc{{PID: 123, Path: "/usr/bin/curl", GID: 375}, {PID: 124, Path: "/Applications/Other.app/Contents/MacOS/Other", GID: 20}}
	if !confinedProcessesRunning(ps, 375) {
		t.Fatal("a confined child command lost the DNS lock")
	}
	if confinedProcessesRunning(ps[1:], 375) || confinedProcessesRunning(ps, 0) {
		t.Fatal("unconfined processes should not trigger the DNS lock")
	}
}
