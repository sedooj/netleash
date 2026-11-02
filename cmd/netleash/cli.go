// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/sedooj/netleash/internal/config"
	"github.com/sedooj/netleash/internal/i18n"
	"github.com/sedooj/netleash/internal/netinfo"
)

var (
	helperPath = config.HelperPath
	logPath    = config.LogPath
)

type status struct {
	Armed bool                  `json:"armed"`
	VPNUp bool                  `json:"vpnUp"`
	Iface string                `json:"iface"`
	TS    float64               `json:"ts"`
	PID   int                   `json:"pid"`
	Note  string                `json:"note"`
	Apps  []config.ProtectedApp `json:"protectedApps"`
}

func cmdStatus() int {
	data, err := os.ReadFile(config.StatusPath)
	if err != nil {
		fmt.Println(i18n.T("✗ daemon is not running (no %s)", config.StatusPath))
		return 2
	}
	var st status
	if json.Unmarshal(data, &st) != nil {
		fmt.Println(i18n.T("✗ unreadable status file"))
		return 2
	}
	if age := time.Since(time.Unix(0, int64(st.TS*1e9))); age > 5*time.Second {
		fmt.Println(i18n.T("✗ daemon has not updated its status for %ds", int(age.Seconds())))
		return 2
	}
	if !st.Armed {
		fmt.Println(i18n.T("✗ protection is NOT armed: %s", st.Note))
		return 2
	}
	if st.VPNUp {
		fmt.Println(i18n.T("● VPN connected (%s) — network allowed", st.Iface))
	} else {
		fmt.Println(i18n.T("○ VPN disconnected — network of the protected app is blocked"))
	}
	fmt.Println(i18n.T("  protection armed, daemon pid %d", st.PID))
	for _, a := range st.Apps {
		label := i18n.T("protection off")
		if a.Enabled {
			label = i18n.T("protection on")
		}
		fmt.Printf("  %s: %s\n", label, a.Path)
	}
	return 0
}

// cmdTest is the leak test: everything from the confined group except the VPN interface must fail.
func cmdTest() int {
	if code := cmdStatus(); code != 0 {
		return code
	}
	// A missing/broken setuid helper is not evidence that the firewall blocked a connection.
	if out, err := exec.Command(helperPath, "/usr/bin/true").CombinedOutput(); err != nil {
		fmt.Println(i18n.T("✗ could not run the protection helper: %s", string(out)))
		return 2
	}
	fmt.Println(i18n.T("→ through the VPN (must work if the VPN is up):"))
	out, err := exec.Command(helperPath, "/usr/bin/curl", "-s", "-m", "8", "-o", "/dev/null",
		"-w", "   api.anthropic.com HTTP %{http_code}\n", "https://api.anthropic.com").Output()
	vpnWorked := err == nil
	if err != nil {
		fmt.Println(i18n.T("   no answer"))
	} else {
		fmt.Print(string(out))
	}
	fmt.Println(i18n.T("→ forced through a physical interface (MUST be blocked):"))
	leak := false
	tested := 0
	ifs, err := net.Interfaces()
	if err != nil {
		fmt.Println(i18n.T("✗ could not list network interfaces: %v", err))
		return 2
	}
	for _, i := range ifs {
		if !netinfo.IsPhysicalInterface(i.Name) || i.Flags&net.FlagUp == 0 || !hasIPv4(i) {
			continue
		}
		tested++
		err := exec.Command(helperPath, "/usr/bin/curl", "-s", "-m", "5", "--interface", i.Name, "-o", "/dev/null", "https://1.1.1.1").Run()
		if err == nil {
			fmt.Println(i18n.T("   ✗ LEAK through %s!", i.Name))
			leak = true
		} else {
			fmt.Println(i18n.T("   ✓ %s is blocked", i.Name))
		}
	}
	if leak {
		fmt.Println(i18n.T("✗ LEAKS FOUND"))
		return 1
	}
	var st status
	data, readErr := os.ReadFile(config.StatusPath)
	if readErr != nil || json.Unmarshal(data, &st) != nil || !st.Armed || time.Since(time.Unix(0, int64(st.TS*1e9))) > 5*time.Second {
		fmt.Println(i18n.T("✗ protection changed during the test; try again"))
		return 2
	}
	if code := networkTestResult(leak, tested, st.VPNUp, vpnWorked); code != 0 {
		fmt.Println(i18n.T("○ test incomplete: no usable physical interface or no VPN response"))
		return code
	}
	fmt.Println(i18n.T("✓ no direct test connections succeeded (not a complete privacy audit)"))
	return 0
}

func networkTestResult(leak bool, tested int, vpnUp, vpnWorked bool) int {
	if leak {
		return 1
	}
	if tested == 0 || (vpnUp && !vpnWorked) {
		return 2
	}
	return 0
}

func hasIPv4(i net.Interface) bool {
	addrs, _ := i.Addrs()
	for _, a := range addrs {
		if ip, _, err := net.ParseCIDR(a.String()); err == nil && ip.To4() != nil {
			return true
		}
	}
	return false
}

func cmdResume() int {
	cmd := exec.Command("/usr/bin/sudo", filepath.Join(config.LibexecDir, "resume.sh"))
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return 1
	}
	return cmdStatus()
}

func execSudo(script string) {
	execTool("/usr/bin/sudo", filepath.Join(config.LibexecDir, script))
}

// execTool replaces the current process (no PATH lookup: absolute paths only).
func execTool(path string, args ...string) {
	if err := syscall.Exec(path, append([]string{path}, args...), os.Environ()); err != nil {
		fmt.Fprintln(os.Stderr, i18n.T("netleash: cannot run %s: %v", path, err))
		os.Exit(127)
	}
}
