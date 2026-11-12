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
			if a.Enabled && a.Kind != config.KindCLI && config.ValidAppPath(a.Path) {
				fmt.Println(a.Path)
			}
		}
		return nil
	}
	if len(args) != 2 {
		return fmt.Errorf("usage: netleash apps [list|paths|add|add-cli|enable|disable|remove|launch <app-path>]")
	}
	action, arg := args[0], args[1]
	kind := ""
	if action == "add-cli" {
		action, kind = "add", config.KindCLI
		if os.Geteuid() != 0 {
			// Resolve the command in the user's own environment (PATH, symlinks), then ask for administrator access.
			resolved, note, err := resolveCLI(arg)
			if err != nil {
				return err
			}
			if note != "" {
				fmt.Println(note)
			}
			self, err := os.Executable()
			if err != nil {
				return err
			}
			execTool("/usr/bin/sudo", self, "apps", "add-cli", resolved)
			return nil
		}
		if !filepath.IsAbs(arg) {
			return fmt.Errorf("%s", i18n.T("give an absolute path to the program or its directory (run without sudo to look it up in PATH)"))
		}
	}
	path := filepath.Clean(arg)
	for _, a := range c.Apps() {
		if kind == "" && filepath.Clean(a.Path) == path {
			kind = a.Kind
		}
	}
	profile := config.ProtectedApp{Path: path, Enabled: true, Kind: kind}
	if !profile.Valid() {
		return fmt.Errorf("invalid application path: %s", path)
	}
	if action == "launch" {
		if kind == config.KindCLI {
			return fmt.Errorf("%s", i18n.T("this is a command-line profile: start the program with netleash run <command>"))
		}
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
	updated, err := config.UpdateProfile(data, action, path, kind)
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
		if kind != config.KindCLI {
			if _, err = appExecutable(path); err != nil {
				return err
			}
		}
		ps, err := proc.List()
		if err != nil {
			return err
		}
		for _, p := range ps {
			if !profile.Matches(p.Path) {
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
	// Restart without touching the firewall: existing confined processes remain confined throughout.
	if err := restartDaemon(); err != nil {
		return fmt.Errorf("settings saved, but daemon restart failed: %w", err)
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

// resolveCLI turns a command name or path into the profile path: the real file behind any symlinks. Claude Code's
// installer keeps every release in <dir>/versions/<version> behind a symlink, so the directory is protected instead,
// otherwise an update would silently move the program out of its profile.
func resolveCLI(arg string) (path, note string, err error) {
	p := arg
	if !strings.Contains(p, "/") {
		if p, err = exec.LookPath(arg); err != nil {
			return "", "", fmt.Errorf("%s", i18n.T("command not found: %s", arg))
		}
	}
	if p, err = filepath.Abs(p); err != nil {
		return "", "", err
	}
	if p, err = filepath.EvalSymlinks(p); err != nil {
		return "", "", err
	}
	if filepath.Base(filepath.Dir(p)) == "versions" {
		dir := filepath.Dir(filepath.Dir(p))
		note = i18n.T("Protecting the whole directory %s so that updates stay protected.", dir)
		p = dir
	}
	if !config.ValidCLIPath(p) {
		return "", "", fmt.Errorf("%s", i18n.T("this program cannot be protected by path: %s", p))
	}
	return p, note, nil
}
