// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package config

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestLoadOverlaysDefaults(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(p, []byte(`{"notify": false, "loopbackBlockPorts": [1234]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	c := Load(p)
	if c.Notify || len(c.LoopbackBlockPorts) != 1 || c.LoopbackBlockPorts[0] != 1234 {
		t.Errorf("overrides not applied: %+v", c)
	}
	if c.GroupName != defaultGroup() || !c.EnforceLauncherOnly || !c.AutoDetectVPNDNS || c.VPNAppPath == "" {
		t.Errorf("defaults lost: %+v", c)
	}
}

func TestLoadMissingOrBrokenFileGivesDefaults(t *testing.T) {
	d := t.TempDir()
	if c := Load(filepath.Join(d, "nope.json")); c.GroupName != defaultGroup() {
		t.Errorf("missing file: %+v", c)
	}
	p := filepath.Join(d, "bad.json")
	_ = os.WriteFile(p, []byte("{not json"), 0o644)
	if c := Load(p); c.GroupName != defaultGroup() || !c.Notify {
		t.Errorf("broken file must yield defaults: %+v", c)
	}
}

func TestDefaultsFollowThePlatform(t *testing.T) {
	c := Default()
	if runtime.GOOS == "linux" {
		if c.GroupName != "netleash" || len(c.Apps()) != 0 || len(c.VPNInterfaces) == 0 {
			t.Errorf("linux defaults: %+v", c)
		}
		return
	}
	if c.GroupName != "_netleash" || len(c.Apps()) != 1 {
		t.Errorf("macOS defaults must stay as before: %+v", c)
	}
}
