// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

//go:build darwin

package proc

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseProcArgs2(t *testing.T) {
	buf := []byte{2, 0, 0, 0}
	buf = append(buf, []byte("/Applications/X.app/Contents/MacOS/X\x00\x00\x00")...)
	buf = append(buf, []byte("/Applications/X.app/Contents/MacOS/X\x00--flag\x00HOME=/tmp\x00")...)
	path, args := parseProcArgs2(buf)
	if path != "/Applications/X.app/Contents/MacOS/X" || len(args) != 2 || args[1] != "--flag" {
		t.Fatalf("got %q %q", path, args)
	}
}

func TestListFindsSelf(t *testing.T) {
	ps, err := List()
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range ps {
		if p.PID == os.Getpid() {
			if p.GID != uint32(os.Getegid()) {
				t.Errorf("gid %d, want effective gid %d", p.GID, os.Getegid())
			}
			if p.Path == "" {
				t.Error("own executable path should be readable")
			}
			return
		}
	}
	t.Fatal("own process not listed")
}

func TestRealPathResolvesSymlinks(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "versions", "1.0.0")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "claude")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if got := realPath(link); got != target {
		t.Errorf("realPath(%q) = %q, want %q", link, got, target)
	}
	if got := realPath("/does/not/exist"); got != "/does/not/exist" {
		t.Errorf("unresolvable paths stay as they are: %q", got)
	}
}
