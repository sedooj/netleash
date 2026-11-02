// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"time"

	"github.com/sedooj/netleash/internal/config"
	"github.com/sedooj/netleash/internal/i18n"
	"github.com/sedooj/netleash/internal/proc"
)

func cmdApps(args []string) int {
	err := manageApps(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

func manageApps(args []string) error {
	c := config.Load(config.ConfigPath)
	if len(args) == 0 || (len(args) == 1 && args[0] == "list") {
		return json.NewEncoder(os.Stdout).Encode(c.Apps())
	}
	if len(args) == 1 && args[0] == "paths" {
		for _, a := range c.Apps() {
			if a.Enabled && config.ValidAppPath(a.Path) {
				fmt.Println(a.Path)
			}
		}
		return nil
	}
	if len(args) != 2 {
		return fmt.Errorf("usage: netleash apps [list|paths|add|enable|disable|remove|launch <app-path>]")
	}
	action, path := args[0], args[1]
	if !config.ValidAppPath(path) {
		return fmt.Errorf("invalid application path: %s", path)
	}
	path = filepath.Clean(path)
	if action == "launch" {
		found := false
		for _, a := range c.Apps() {
			if a.Enabled && a.Path == path {
				found = true
			}
		}
		if !found {
			return fmt.Errorf("application is not enabled: %s", path)
		}
		var st struct {
			Apps []config.ProtectedApp `json:"protectedApps"`
			TS   float64               `json:"ts"`
		}
		data, err := os.ReadFile(config.StatusPath)
		if err != nil {
			return err
		}
		if json.Unmarshal(data, &st) != nil || time.Since(time.Unix(0, int64(st.TS*1e9))) > 5*time.Second || !reflect.DeepEqual(st.Apps, c.Apps()) {
			return fmt.Errorf("daemon has not applied the application settings; check netleash status")
		}
		binary, err := appExecutable(path)
		if err != nil {
			return err
		}
		execTool(helperPath, []string{"--disclaim", binary}...)
		return nil
	}
	if action != "add" && action != "enable" && action != "disable" && action != "remove" {
		return fmt.Errorf("unknown application action: %s", action)
	}
	if os.Geteuid() != 0 {
		return fmt.Errorf("%s", i18n.T("Administrator access is required to change protected applications."))
	}
	for _, p := range []string{config.ConfigDir, config.ConfigPath} {
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		st, ok := fi.Sys().(*syscall.Stat_t)
		if !ok || st.Uid != 0 || fi.Mode().Perm()&0o022 != 0 || (p == config.ConfigDir && !fi.IsDir()) || (p == config.ConfigPath && !fi.Mode().IsRegular()) {
			return fmt.Errorf("untrusted configuration: %s", p)
		}
	}
	// Serialize read-modify-write and reload, including edits from more than one settings window.
	lock, err := os.OpenFile(filepath.Join(config.ConfigDir, ".apps.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	data, err := os.ReadFile(config.ConfigPath)
	if err != nil {
		return err
	}
	updated, err := config.UpdateApp(data, action, path)
	if err != nil {
		return err
	}
	if action == "add" || action == "enable" {
		canonical, err := filepath.EvalSymlinks(path)
		if err != nil {
			return err
		}
		if canonical != path {
			return fmt.Errorf("select the original application at %s", canonical)
		}
		if _, err = appExecutable(path); err != nil {
			return err
		}
		ps, err := proc.List()
		if err != nil {
			return err
		}
		for _, p := range ps {
			if !strings.HasPrefix(p.Path, path+"/") {
				continue
			}
			ignored := false
			for _, s := range c.IgnoreCommandSubstrings {
				if strings.Contains(p.Path, s) {
					ignored = true
				}
			}
			if !ignored {
				return fmt.Errorf("%s", i18n.T("Quit the application before enabling protection: %s", path))
			}
		}
	}
	if err = config.WriteAtomic(config.ConfigPath, updated); err != nil {
		return err
	}
	// Restart without touching pf: existing confined processes remain confined throughout.
	if out, err := exec.Command("/bin/launchctl", "kickstart", "-k", "system/"+config.DaemonLabel).CombinedOutput(); err != nil {
		return fmt.Errorf("settings saved, but daemon restart failed: %s: %w", strings.TrimSpace(string(out)), err)
	}
	var expected config.Config
	if err = json.Unmarshal(updated, &expected); err != nil {
		return err
	}
	for deadline := time.Now().Add(8 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		var st struct {
			Apps []config.ProtectedApp `json:"protectedApps"`
			TS   float64               `json:"ts"`
		}
		data, err := os.ReadFile(config.StatusPath)
		if err == nil && json.Unmarshal(data, &st) == nil && reflect.DeepEqual(st.Apps, expected.Apps()) && time.Since(time.Unix(0, int64(st.TS*1e9))) < 2*time.Second {
			return nil
		}
	}
	return fmt.Errorf("settings saved, but the daemon has not confirmed them; check netleash status")
}

func appExecutable(path string) (string, error) {
	out, err := exec.Command("/usr/bin/plutil", "-extract", "CFBundleExecutable", "raw", "-o", "-", filepath.Join(path, "Contents", "Info.plist")).Output()
	if err != nil {
		return "", fmt.Errorf("invalid application bundle: %s", path)
	}
	name := strings.TrimSpace(string(out))
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\x00\r\n") {
		return "", fmt.Errorf("invalid bundle executable")
	}
	binary := filepath.Join(path, "Contents", "MacOS", name)
	fi, err := os.Stat(binary)
	if err != nil {
		return "", err
	}
	if !fi.Mode().IsRegular() || fi.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("not an executable: %s", binary)
	}
	canonical, err := filepath.EvalSymlinks(binary)
	if err != nil {
		return "", err
	}
	root, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(canonical, root+"/") {
		return "", fmt.Errorf("executable is outside the application bundle")
	}
	return binary, nil
}
