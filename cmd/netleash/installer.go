// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/sedooj/netleash/internal/config"
)

func cmdStartInstaller(args []string) int {
	if len(args) != 1 || os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "installer-start requires administrator access and an absolute install.sh path")
		return 1
	}
	pid, err := startDetachedInstaller(args[0], config.InstallLogPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(pid)
	return 0
}

// Exercise the production launch implementation with a harmless script in a private temporary directory.
// This command is also called through AppleScript by the app's installer validation; it never installs anything.
func checkInstallerLaunch() error {
	dir, err := os.MkdirTemp("", "netleash-installer-probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	script, log := filepath.Join(dir, "install.sh"), filepath.Join(dir, "install.log")
	if err = os.WriteFile(script, []byte("#!/bin/bash\nsleep 0.1\necho NETLEASH_PROBE_STDOUT\necho NETLEASH_PROBE_STDERR >&2\n"), 0o755); err != nil {
		return err
	}
	if _, err = startDetachedInstaller(script, log); err != nil {
		return err
	}
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		data, _ := os.ReadFile(log)
		if strings.Contains(string(data), "NETLEASH_PROBE_STDOUT") && strings.Contains(string(data), "NETLEASH_PROBE_STDERR") {
			return nil
		}
	}
	data, _ := os.ReadFile(log)
	return fmt.Errorf("detached installer probe failed: %s", data)
}

// Start a new session with all stdio detached. macOS nohup can fail before exec when
// Authorization Services provides no console, so the GUI must not use it to launch installers.
// Open the installation log first: even validation and exec failures leave diagnostics.
func startDetachedInstaller(script, logPath string) (pid int, err error) {
	fd, err := syscall.Open(logPath, syscall.O_CREAT|syscall.O_WRONLY|syscall.O_APPEND|syscall.O_NOFOLLOW, 0o644)
	if err != nil {
		return 0, fmt.Errorf("open installation log: %w", err)
	}
	log := os.NewFile(uintptr(fd), logPath)
	defer log.Close()
	defer func() {
		if err != nil {
			fmt.Fprintf(log, "Installer launch failed: %v\n", err)
		}
	}()
	fi, err := log.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return 0, fmt.Errorf("installation log is not a regular file")
	}
	fmt.Fprintf(log, "--- %s starting installer\n", time.Now().Format(time.RFC3339))
	if !filepath.IsAbs(script) || filepath.Base(script) != "install.sh" {
		return 0, fmt.Errorf("invalid installer path")
	}
	fi, err = os.Lstat(script)
	if err != nil {
		return 0, err
	}
	if !fi.Mode().IsRegular() || fi.Mode().Perm()&0o111 == 0 {
		return 0, fmt.Errorf("installer is not a regular executable script")
	}
	input, err := os.Open(os.DevNull)
	if err != nil {
		return 0, err
	}
	defer input.Close()
	command := exec.Command("/bin/bash", script, "-y")
	command.Dir = filepath.Dir(script)
	command.Stdin, command.Stdout, command.Stderr = input, log, log
	// Setsid creates a session without a controlling terminal. Do not set Noctty:
	// fd 0 is /dev/null, and a TIOCNOTTY ioctl on it would itself fail.
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = command.Start(); err != nil {
		return 0, err
	}
	pid = command.Process.Pid
	if err = command.Process.Release(); err != nil {
		return 0, err
	}
	return pid, nil
}
