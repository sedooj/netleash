// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestAppListMigrationAndToggles(t *testing.T) {
	data := []byte(`{"protectedAppPath":"/Applications/Legacy.app","notify":false,"futureKey":{"keep":123}}`)
	var err error
	for _, step := range []struct {
		action, path string
		want         []ProtectedApp
	}{
		{"add", "/Applications/Codex.app", []ProtectedApp{{"/Applications/Legacy.app", true}, {"/Applications/Codex.app", true}}},
		{"add", "/Applications/Codex.app", []ProtectedApp{{"/Applications/Legacy.app", true}, {"/Applications/Codex.app", true}}},
		{"disable", "/Applications/Codex.app", []ProtectedApp{{"/Applications/Legacy.app", true}, {"/Applications/Codex.app", false}}},
		{"enable", "/Applications/Codex.app", []ProtectedApp{{"/Applications/Legacy.app", true}, {"/Applications/Codex.app", true}}},
		{"remove", "/Applications/Legacy.app", []ProtectedApp{{"/Applications/Codex.app", true}}},
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
