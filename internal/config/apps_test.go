// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestAppListMigrationAndToggles(t *testing.T) {
	data := []byte(`{"protectedAppPath":"/Applications/Legacy.app","notify":false,"futureKey":{"keep":123}}`)
	var err error
	for _, step := range []struct {
		action, path string
		want         []ProtectedApp
	}{
		{"add", "/Applications/Codex.app", []ProtectedApp{{Path: "/Applications/Legacy.app", Enabled: true}, {Path: "/Applications/Codex.app", Enabled: true}}},
		{"add", "/Applications/Codex.app", []ProtectedApp{{Path: "/Applications/Legacy.app", Enabled: true}, {Path: "/Applications/Codex.app", Enabled: true}}},
		{"disable", "/Applications/Codex.app", []ProtectedApp{{Path: "/Applications/Legacy.app", Enabled: true}, {Path: "/Applications/Codex.app", Enabled: false}}},
		{"enable", "/Applications/Codex.app", []ProtectedApp{{Path: "/Applications/Legacy.app", Enabled: true}, {Path: "/Applications/Codex.app", Enabled: true}}},
		{"remove", "/Applications/Legacy.app", []ProtectedApp{{Path: "/Applications/Codex.app", Enabled: true}}},
		{"remove", "/Applications/Codex.app", []ProtectedApp{}},
	} {
		data, err = UpdateApp(data, step.action, step.path)
		if err != nil {
			t.Fatal(err)
		}
		c := Default()
		if err := json.Unmarshal(data, &c); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(c.Apps(), step.want) {
			t.Fatalf("%s: got %+v, want %+v", step.action, c.Apps(), step.want)
		}
		var doc map[string]json.RawMessage
		_ = json.Unmarshal(data, &doc)
		var future map[string]int
		_ = json.Unmarshal(doc["futureKey"], &future)
		if c.Notify || future["keep"] != 123 {
			t.Fatalf("unrelated settings lost: %s", data)
		}
	}
}

func TestApplicationMatching(t *testing.T) {
	c := Default()
	c.ProtectedAppPath = "/Applications/Claude.app" // the legacy single-app setting (the default only on macOS)
	if !c.ProtectsExecutable("/Applications/Claude.app/Contents/MacOS/Claude") {
		t.Fatal("legacy app lost")
	}
	data := []byte(`{"protectedApps":[{"path":"/Applications/Claude.app"},{"path":"/Applications/Codex.app","enabled":true},{"path":"/Applications/Disabled.app","enabled":false}]}`)
	if err := json.Unmarshal(data, &c); err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]bool{
		"/Applications/Claude.app/Contents/MacOS/Claude":                                     true,
		"/Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Helper": true,
		"/Applications/Codex.app.backup/Contents/MacOS/Codex":                                false,
		"/Applications/Disabled.app/Contents/MacOS/Disabled":                                 false,
		"/Applications/Other.app/Contents/MacOS/Other":                                       false,
		"": false,
	} {
		if got := c.ProtectsExecutable(path); got != want {
			t.Errorf("%s: got %v, want %v", path, got, want)
		}
	}
	if err := json.Unmarshal([]byte(`{"protectedApps":[]}`), &c); err != nil {
		t.Fatal(err)
	}
	if len(c.Apps()) != 0 || c.ProtectsExecutable("/Applications/Claude.app/Contents/MacOS/Claude") {
		t.Fatal("empty list must not restore the default app")
	}
}

func TestAppEditsRejectInvalidInput(t *testing.T) {
	for _, data := range []string{`null`, `{`, `[]`, `{"protectedApps":"wrong"}`, `{"protectedApps":[{"path":"/"}]}`} {
		if _, err := UpdateApp([]byte(data), "add", "/Applications/Codex.app"); err == nil {
			t.Errorf("accepted %s", data)
		}
	}
	for _, path := range []string{"/", "Claude.app", "/Applications/Claude.app\nother", "/Applications/Claude.app\x00"} {
		if _, err := UpdateApp([]byte(`{}`), "add", path); err == nil {
			t.Errorf("accepted %q", path)
		}
	}
	if _, err := UpdateApp([]byte(`{}`), "enable", "/Applications/Unknown.app"); err == nil {
		t.Fatal("enabled an unknown app")
	}
	path := "/Applications/John's $(touch nope) `test`.app"
	if _, err := UpdateApp([]byte(`{}`), "add", path); err != nil {
		t.Fatal("literal shell characters in a filename must be supported:", err)
	}
}

func TestAtomicAppSettings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := WriteAtomic(path, []byte(`{"protectedApps":[]}`)); err != nil {
		t.Fatal(err)
	}
	if c := Load(path); len(c.Apps()) != 0 {
		t.Fatal("empty list did not survive a write and load")
	}
	fi, err := os.Stat(path)
	if err != nil || fi.Mode().Perm() != 0o644 {
		t.Fatalf("unexpected config permissions: %v %v", fi, err)
	}
}

func TestCLIProfileMatching(t *testing.T) {
	file := ProtectedApp{Path: "/home/u/bin/claude", Enabled: true, Kind: KindCLI}
	dir := ProtectedApp{Path: "/home/u/.local/share/claude", Enabled: true, Kind: KindCLI}
	for _, tc := range []struct {
		a    ProtectedApp
		path string
		want bool
	}{
		{file, "/home/u/bin/claude", true},
		{file, "/home/u/bin/claude-other", false},
		{file, "/home/u/bin/claude/x", true},
		{dir, "/home/u/.local/share/claude/versions/2.1.0", true},
		{dir, "/home/u/.local/share/claude-evil/x", false},
		{dir, "/bin/sh", false},
	} {
		if got := tc.a.Matches(tc.path); got != tc.want {
			t.Errorf("%+v matches %q = %v, want %v", tc.a, tc.path, got, tc.want)
		}
	}
	app := ProtectedApp{Path: "/Applications/Claude.app", Enabled: true}
	if !app.Matches("/Applications/Claude.app/Contents/MacOS/Claude") || app.Matches("/Applications/Claude.app") {
		t.Error("app bundles match their contents only")
	}
}

// A command-line profile must never be able to swallow system programs or whole shared directories: the daemon
// terminates matching processes that were started outside the launcher.
func TestCLIProfileRefusesDangerousPaths(t *testing.T) {
	for _, p := range []string{"/", "/bin/sh", "/usr/bin/curl", "/usr/bin", "/usr/local/bin", "/usr/local", "/opt", "/opt/homebrew/bin",
		"/Users/x", "/home/x", "/root", "/Applications/Claude.app", "/Users/x/Applications", "/opt/x/node", "/home/x/bin/bash",
		"relative/claude", "/home/x/../y/claude", "/home/x/claude\n", "/System/Library/x", "/var/lib/x", "/usr/local/libexec/netleash/netleash"} {
		if ValidCLIPath(p) {
			t.Errorf("%q must be refused", p)
		}
	}
	for _, p := range []string{"/home/x/.local/share/claude", "/Users/x/.local/bin/claude", "/opt/claude/claude", "/usr/local/bin/claude"} {
		if !ValidCLIPath(p) {
			t.Errorf("%q must be accepted", p)
		}
	}
}

func TestUpdateProfileAddsCLI(t *testing.T) {
	out, err := UpdateProfile([]byte(`{"protectedApps":[]}`), "add", "/home/x/.local/share/claude", KindCLI)
	if err != nil {
		t.Fatal(err)
	}
	var c Config
	if err := json.Unmarshal(out, &c); err != nil || len(c.Apps()) != 1 || c.Apps()[0].Kind != KindCLI {
		t.Fatalf("%s %v", out, err)
	}
	if _, err := UpdateProfile(out, "add", "/bin/sh", KindCLI); err == nil {
		t.Error("system programs must be refused")
	}
	if out, err = UpdateProfile(out, "disable", "/home/x/.local/share/claude", ""); err != nil || !strings.Contains(string(out), `"enabled": false`) {
		t.Errorf("disable must find the entry by path: %s %v", out, err)
	}
}
