// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

// Package config holds the daemon configuration and the well-known install paths.
package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// Install layout. Everything is derived from Name so a fork can rename the project in one place.
const (
	Name           = "netleash"
	LibexecDir     = "/usr/local/libexec/" + Name
	ConfigDir      = "/usr/local/etc/" + Name
	StateDir       = "/var/run/" + Name
	LogPath        = "/var/log/" + Name + ".log"
	InstallLogPath = "/var/log/" + Name + "-install.log"

	ConfigPath     = ConfigDir + "/config.json"
	LearnedDNSPath = ConfigDir + "/learned-dns.json"
	PFTokenPath    = ConfigDir + "/pf-token"
	StatusPath     = StateDir + "/status.json"
	HelperPath     = LibexecDir + "/" + Name + "-exec"
	DaemonLabel    = "org.netleash.daemon"

	// AnchorName lives inside Apple's com.apple/* namespace: the stock /etc/pf.conf already references it, so other
	// programs reloading the main ruleset (e.g. a VPN kill switch) do not remove our rules.
	AnchorName = "com.apple/050." + Name
)

// Config is read from ConfigPath. Every key is optional; missing keys keep their defaults.
type Config struct {
	// GroupName is the macOS group whose network is confined.
	GroupName string `json:"groupName"`
	// ProtectedAppPath is the application whose network access is restricted.
	ProtectedAppPath string `json:"protectedAppPath"`
	// ProtectedApps replaces ProtectedAppPath when present, including an explicitly empty list.
	ProtectedApps []ProtectedApp `json:"protectedApps"`
	// VPNAppPath is the VPN application whose tunnel interface is the only permitted route (macOS).
	VPNAppPath string `json:"vpnAppPath"`
	// VPNInterfaces are the tunnel interface names (shell-style patterns such as "wg*") that count as the VPN (Linux).
	VPNInterfaces []string `json:"vpnInterfaces"`
	// EnforceLauncherOnly kills protected-app processes that were not started through the launcher.
	EnforceLauncherOnly bool `json:"enforceLauncherOnly"`
	Notify              bool `json:"notify"`
	// LoopbackBlockPorts are local proxy ports the protected app must not use (they could bypass the VPN).
	LoopbackBlockPorts []int `json:"loopbackBlockPorts"`
	// IgnoreCommandSubstrings are paths inside the app that are not killed as "unprotected launch". The Squirrel updater
	// is started by launchd with another gid, does not use the network, and launchd restarts it if it is killed.
	IgnoreCommandSubstrings []string `json:"ignoreCommandSubstrings"`
	// VPNDNSServers are DNS servers of the VPN that must never be reachable through physical interfaces (manual part).
	VPNDNSServers []string `json:"vpnDnsServers"`
	// AutoDetectVPNDNS extends VPNDNSServers with private addresses from the system resolvers that have a host route
	// via the VPN interface.
	AutoDetectVPNDNS bool `json:"autoDetectVpnDns"`
}

// ProtectedApp describes an original app bundle. Omitted enabled means true.
type ProtectedApp struct {
	Path    string `json:"path"`
	Enabled bool   `json:"enabled"`
	// Kind is KindCLI for a command-line program (a file or a directory of executables); empty means an app bundle.
	Kind string `json:"kind,omitempty"`
}

// KindCLI marks a command-line profile such as Claude Code in a terminal.
const KindCLI = "cli"

func (a *ProtectedApp) UnmarshalJSON(data []byte) error {
	type plain ProtectedApp
	v := plain{Enabled: true}
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	*a = ProtectedApp(v)
	return nil
}

// Apps preserves the legacy single-app configuration until an explicit list is saved.
func (c Config) Apps() []ProtectedApp {
	if c.ProtectedApps != nil {
		return c.ProtectedApps
	}
	if c.ProtectedAppPath == "" {
		return []ProtectedApp{}
	}
	return []ProtectedApp{{Path: c.ProtectedAppPath, Enabled: true}}
}

// ProtectsExecutable matches bundle boundaries, never similarly named neighboring apps.
func (c Config) ProtectsExecutable(path string) bool {
	for _, a := range c.Apps() {
		if a.Enabled && a.Matches(path) {
			return true
		}
	}
	return false
}

// Matches reports whether the executable path belongs to the profile: inside the app bundle, or the program itself
// (or anything inside the directory) for a command-line profile.
func (a ProtectedApp) Matches(path string) bool {
	if !a.Valid() {
		return false
	}
	base := filepath.Clean(a.Path)
	if a.Kind == KindCLI {
		return path == base || strings.HasPrefix(path, base+"/")
	}
	return strings.HasPrefix(path, base+"/")
}

// Valid reports whether the profile is acceptable for the kind it declares.
func (a ProtectedApp) Valid() bool {
	if a.Kind == KindCLI {
		return ValidCLIPath(a.Path)
	}
	return ValidAppPath(a.Path)
}

// ValidAppPath also keeps paths safe to exchange with the installer's line-based interface.
func ValidAppPath(path string) bool {
	return filepath.IsAbs(path) && strings.HasSuffix(filepath.Clean(path), ".app") && !strings.ContainsAny(path, "\x00\r\n")
}

// Directories and interpreters that must never become a command-line profile: the daemon terminates matching
// processes that were started outside the launcher, so protecting /bin/sh or node would break the whole system.
var (
	systemRoots = []string{"/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/lib", "/lib64",
		"/System", "/Library", "/etc", "/boot", "/dev", "/proc", "/sys", "/var", "/private"}
	interpreters = map[string]bool{"sh": true, "bash": true, "zsh": true, "fish": true, "dash": true, "ksh": true, "csh": true,
		"tcsh": true, "node": true, "nodejs": true, "deno": true, "bun": true, "python": true, "python3": true, "ruby": true,
		"perl": true, "php": true, "java": true, "env": true, "sudo": true, "login": true, "launchd": true, "init": true,
		"systemd": true, "netleash": true, "netleash-exec": true}
)

// ValidCLIPath accepts an absolute, normalized path to a program or to a directory of programs. System locations,
// shared containers such as /usr/local/bin, whole home directories and interpreters are refused.
func ValidCLIPath(path string) bool {
	if !filepath.IsAbs(path) || strings.ContainsAny(path, "\x00\r\n") || filepath.Clean(path) != path {
		return false
	}
	if len(strings.Split(strings.Trim(path, "/"), "/")) < 3 { // "/", /Users/x, /home/x, /opt/x
		return false
	}
	for _, r := range systemRoots {
		if path == r || strings.HasPrefix(path, r+"/") {
			return false
		}
	}
	switch filepath.Base(path) {
	case "bin", "sbin", "lib", "libexec", "Applications", "Contents", "MacOS":
		return false
	}
	switch path {
	case "/usr/local", "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/opt/homebrew", "/opt/homebrew/bin":
		return false
	}
	if strings.HasSuffix(path, ".app") || strings.Contains(path, ".app/") || path == LibexecDir || strings.HasPrefix(path, LibexecDir+"/") {
		return false
	}
	return !interpreters[filepath.Base(path)]
}

// defaultGroup follows each system's naming convention: macOS system groups start with an underscore, Linux
// tools reject such names.
func defaultGroup() string {
	if runtime.GOOS == "linux" {
		return Name
	}
	return "_" + Name
}

// defaultProtectedApp keeps the historical macOS default; other systems start with nothing protected.
func defaultProtectedApp() string {
	if runtime.GOOS == "darwin" {
		return "/Applications/Claude.app"
	}
	return ""
}

// Default returns the configuration used when no config file exists.
func Default() Config {
	return Config{
		GroupName:               defaultGroup(),
		ProtectedAppPath:        defaultProtectedApp(),
		VPNAppPath:              "/Applications/AmneziaVPN.app",
		VPNInterfaces:           []string{"amn0"},
		EnforceLauncherOnly:     true,
		Notify:                  true,
		LoopbackBlockPorts:      []int{7890, 7891, 7892, 7897, 9090, 9097},
		IgnoreCommandSubstrings: []string{"/Squirrel.framework/"},
		VPNDNSServers:           []string{"100.64.0.1"},
		AutoDetectVPNDNS:        true,
	}
}

// Load reads path over the defaults. A missing or invalid file yields the defaults.
func Load(path string) Config {
	c := Default()
	data, err := os.ReadFile(path)
	if err != nil {
		return c
	}
	if json.Unmarshal(data, &c) != nil {
		return Default()
	}
	return c
}
