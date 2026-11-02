// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

// Command netleash is the command-line interface and the root daemon of Netleash.
package main

import (
	"fmt"
	"os"
	"runtime"

	"github.com/sedooj/netleash/internal/i18n"
)

// Set at build time by build.sh: -ldflags "-X main.version=0.1.0 -X main.commit=abc1234 -X main.date=2026-01-01T00:00:00Z".
// Release builds carry a clean semantic version; local builds are marked 0.1.0-dev+<commit>.
var (
	version = "dev"
	commit  = ""
	date    = ""
)

func versionString() string {
	s := "netleash " + version
	if commit != "" || date != "" {
		s += fmt.Sprintf(" (commit %s, built %s, %s/%s)", commit, date, runtime.GOOS, runtime.GOARCH)
	}
	return s
}

func main() {
	cmd := "status"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	switch cmd {
	case "installer-start":
		os.Exit(cmdStartInstaller(os.Args[2:]))
	case "installer-check":
		if err := checkInstallerLaunch(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("OK: detached installer executed and both output streams were captured")
	case "apps":
		os.Exit(cmdApps(os.Args[2:]))
	case "daemon":
		runDaemon()
	case "status":
		os.Exit(cmdStatus())
	case "test":
		os.Exit(cmdTest())
	case "panic":
		execSudo("panic.sh")
	case "resume":
		os.Exit(cmdResume())
	case "update":
		if len(os.Args) > 2 && (os.Args[2] == "--help" || os.Args[2] == "-h") {
			fmt.Print(i18n.UsageUpdate())
			return
		}
		os.Exit(cmdUpdate(os.Args[2:]))
	case "log":
		execTool("/usr/bin/tail", "-f", logPath)
	case "run":
		if len(os.Args) < 3 {
			fmt.Fprint(os.Stderr, i18n.UsageMain())
			os.Exit(64)
		}
		execTool(helperPath, os.Args[2:]...)
	case "version", "--version", "-v":
		fmt.Println(versionString())
	case "help", "--help", "-h":
		fmt.Print(i18n.UsageMain())
	default:
		fmt.Fprint(os.Stderr, i18n.UsageMain())
		os.Exit(64)
	}
}
