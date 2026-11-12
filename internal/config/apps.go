// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// UpdateApp returns a configuration document with only the app list changed.
// Keep unknown keys and refuse malformed documents rather than silently replacing settings.
func UpdateApp(data []byte, action, path string) ([]byte, error) {
	return UpdateProfile(data, action, path, "")
}

// UpdateProfile is UpdateApp for an app bundle (kind "") or a command-line profile (KindCLI); kind only matters
// when adding, the other actions find the entry by its path.
func UpdateProfile(data []byte, action, path, kind string) ([]byte, error) {
	path = filepath.Clean(path)
	if path == "." || strings.ContainsAny(path, "\x00\r\n") {
		return nil, fmt.Errorf("invalid application path: %s", path)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	if doc == nil {
		return nil, fmt.Errorf("configuration must be a JSON object")
	}
	c := Default()
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, err
	}
	apps := append([]ProtectedApp{}, c.Apps()...)
	for _, a := range apps {
		if !a.Valid() {
			return nil, fmt.Errorf("invalid configured application path: %s", a.Path)
		}
	}
	index := -1
	for i, a := range apps {
		if filepath.Clean(a.Path) == path {
			index = i
			break
		}
	}
	if index >= 0 {
		kind = apps[index].Kind // an existing entry decides what it is
	}
	if !(ProtectedApp{Path: path, Kind: kind}).Valid() {
		return nil, fmt.Errorf("invalid application path: %s", path)
	}
	switch action {
	case "add":
		if index < 0 {
			apps = append(apps, ProtectedApp{Path: path, Enabled: true, Kind: kind})
		}
	case "enable", "disable":
		if index < 0 {
			return nil, fmt.Errorf("application is not configured: %s", path)
		}
		apps[index].Enabled = action == "enable"
	case "remove":
		if index < 0 {
			return nil, fmt.Errorf("application is not configured: %s", path)
		}
		apps = append(apps[:index], apps[index+1:]...)
	default:
		return nil, fmt.Errorf("unknown application action: %s", action)
	}
	doc["protectedApps"], _ = json.Marshal(apps)
	out, err := json.MarshalIndent(doc, "", "  ")
	return append(out, '\n'), err
}

// WriteAtomic publishes a complete document; a failed write leaves the previous config intact.
func WriteAtomic(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".config-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0o644); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}
