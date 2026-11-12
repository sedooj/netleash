// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package proc

import (
	"bytes"
	"os"
	"strconv"
	"strings"
	"sync"
)

type cacheKey struct {
	pid   int
	start uint64
}

var (
	mu    sync.Mutex
	paths = map[cacheKey]string{}
)

// parseStatusGID returns the effective gid from the contents of /proc/<pid>/status ("Gid: real effective saved fs").
func parseStatusGID(status string) (uint32, bool) {
	for _, line := range strings.Split(status, "\n") {
		if !strings.HasPrefix(line, "Gid:") {
			continue
		}
		f := strings.Fields(line[len("Gid:"):])
		if len(f) < 2 {
			return 0, false
		}
		n, err := strconv.ParseUint(f[1], 10, 32)
		return uint32(n), err == nil
	}
	return 0, false
}

// parseStartTime returns the start time (clock ticks since boot) from /proc/<pid>/stat. The command name is in
// parentheses and may itself contain spaces and parentheses, so fields are counted after the LAST ")".
func parseStartTime(stat string) (uint64, bool) {
	i := strings.LastIndexByte(stat, ')')
	if i < 0 {
		return 0, false
	}
	f := strings.Fields(stat[i+1:])
	if len(f) < 20 { // field 22 overall is index 19 after the command name and the state field
		return 0, false
	}
	n, err := strconv.ParseUint(f[19], 10, 64)
	return n, err == nil
}

func exePath(pid int) string {
	p, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
	if err != nil {
		return ""
	}
	return strings.TrimSuffix(p, " (deleted)")
}

// Args returns the executable path and arguments of pid (root can read any process).
func Args(pid int) (string, []string) {
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
	if err != nil {
		return "", nil
	}
	var args []string
	for _, a := range bytes.Split(bytes.TrimRight(data, "\x00"), []byte{0}) {
		args = append(args, string(a))
	}
	return exePath(pid), args
}

// List returns all processes. Executable paths are cached per (pid, start time).
func List() ([]Proc, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	mu.Lock()
	defer mu.Unlock()
	live := make(map[cacheKey]string, len(entries))
	out := make([]Proc, 0, len(entries))
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid <= 0 {
			continue
		}
		dir := "/proc/" + e.Name()
		status, err := os.ReadFile(dir + "/status")
		if err != nil {
			continue // the process exited meanwhile
		}
		gid, ok := parseStatusGID(string(status))
		if !ok {
			continue
		}
		stat, _ := os.ReadFile(dir + "/stat")
		start, _ := parseStartTime(string(stat))
		key := cacheKey{pid, start}
		path, cached := paths[key]
		if !cached {
			path = exePath(pid)
		}
		live[key] = path
		out = append(out, Proc{PID: pid, GID: gid, Path: path})
	}
	paths = live
	return out, nil
}
