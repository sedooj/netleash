// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package proc

import (
	"bytes"
	"encoding/binary"
	"path/filepath"
	"sync"

	"golang.org/x/sys/unix"
)

type cacheKey struct {
	pid  int
	sec  int64
	usec int64
	comm string
}

var (
	mu    sync.Mutex
	paths = map[cacheKey]string{}
)

func comm(k *unix.KinfoProc) string {
	b := make([]byte, 0, len(k.Proc.P_comm))
	for _, c := range k.Proc.P_comm {
		if c == 0 {
			break
		}
		b = append(b, byte(c))
	}
	return string(b)
}

// parseProcArgs2 extracts the executable path and the arguments from a kern.procargs2 buffer:
// int32 argc, exec path (NUL-terminated), NUL padding, argv[0..argc-1], then the environment.
func parseProcArgs2(buf []byte) (path string, args []string) {
	if len(buf) < 4 {
		return "", nil
	}
	argc := int(binary.LittleEndian.Uint32(buf[:4]))
	rest := buf[4:]
	end := bytes.IndexByte(rest, 0)
	if end < 0 {
		return string(rest), nil
	}
	path = string(rest[:end])
	rest = bytes.TrimLeft(rest[end:], "\x00")
	for i := 0; i < argc; i++ {
		end = bytes.IndexByte(rest, 0)
		if end < 0 {
			args = append(args, string(rest))
			break
		}
		args = append(args, string(rest[:end]))
		rest = rest[end+1:]
	}
	return path, args
}

// Args returns the executable path and arguments of pid (root can read any process).
func Args(pid int) (string, []string) {
	buf, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", nil
	}
	return parseProcArgs2(buf)
}

// realPath resolves symlinks: the kernel reports the path a program was started by, which for a command such as
// ~/.local/bin/claude is a link to the real file. Profiles are matched against real paths.
func realPath(path string) string {
	if path == "" || !filepath.IsAbs(path) {
		return path
	}
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

// List returns all processes. Executable paths are cached per (pid, start time, comm), so repeated calls
// (the daemon scans every 50 ms) cost one sysctl plus a map lookup per process.
func List() ([]Proc, error) {
	kps, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return nil, err
	}
	mu.Lock()
	defer mu.Unlock()
	live := make(map[cacheKey]string, len(kps))
	out := make([]Proc, 0, len(kps))
	for i := range kps {
		k := &kps[i]
		pid := int(k.Proc.P_pid)
		if pid <= 0 {
			continue
		}
		key := cacheKey{pid, int64(k.Proc.P_starttime.Sec), int64(k.Proc.P_starttime.Usec), comm(k)}
		path, ok := paths[key]
		if !ok {
			path, _ = Args(pid)
			path = realPath(path)
		}
		live[key] = path
		out = append(out, Proc{PID: pid, GID: k.Eproc.Ucred.Groups[0], Path: path})
	}
	paths = live // drops entries of processes that are gone
	return out, nil
}
