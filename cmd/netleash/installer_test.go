// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Re-exec the test binary to prove that the installer outlives the process which starts it,
// with no terminal and no inherited stdout pipe. No system installation or privileges are used.
func TestInstallerSurvivesStarterExit(t *testing.T) {
	if os.Getenv("NETLEASH_INSTALLER_TEST_CHILD") == "1" {
		pid, err := startDetachedInstaller(os.Getenv("NETLEASH_INSTALLER_TEST_SCRIPT"), os.Getenv("NETLEASH_INSTALLER_TEST_LOG"))
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println(pid)
		os.Exit(0)
	}
	dir := t.TempDir()
	script, log := filepath.Join(dir, "install.sh"), filepath.Join(dir, "install.log")
	// Sleep until the starter exits, then write to both streams. This used to fail inside nohup.
	if err := os.WriteFile(script, []byte("#!/bin/bash\nsleep 0.3\necho INSTALLER_STDOUT\necho INSTALLER_STDERR >&2\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestInstallerSurvivesStarterExit$")
	command.Env = append(os.Environ(), "NETLEASH_INSTALLER_TEST_CHILD=1", "NETLEASH_INSTALLER_TEST_SCRIPT="+script, "NETLEASH_INSTALLER_TEST_LOG="+log)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	out, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("starter: %v: %s", err, out)
	}
	if pid, err := strconv.Atoi(strings.TrimSpace(string(out))); err != nil || pid <= 0 {
		t.Fatalf("invalid child pid: %q", out)
	}
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		data, _ := os.ReadFile(log)
		if strings.Contains(string(data), "INSTALLER_STDOUT") && strings.Contains(string(data), "INSTALLER_STDERR") {
			return
		}
	}
	t.Fatal("installer did not run after its starter exited")
}

func TestInstallerLogsLaunchFailures(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "install.log")
	if _, err := startDetachedInstaller(filepath.Join(dir, "missing", "install.sh"), log); err == nil {
		t.Fatal("accepted missing installer")
	}
	data, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(data), "Installer launch failed:") {
		t.Fatalf("launch failure was not logged: %q (%v)", data, err)
	}
}

func TestInstallerDoesNotFollowLogSymlinks(t *testing.T) {
	dir := t.TempDir()
	target, link := filepath.Join(dir, "keep"), filepath.Join(dir, "install.log")
	if err := os.WriteFile(target, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := startDetachedInstaller(filepath.Join(dir, "install.sh"), link); err == nil {
		t.Fatal("followed log symlink")
	}
	if data, _ := os.ReadFile(target); string(data) != "keep" {
		t.Fatal("modified symlink target")
	}
}
