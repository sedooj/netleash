// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

// Package update finds, downloads, verifies and unpacks Netleash releases. The network access itself is injected
// (Fetcher), so the daemon-confined route through the VPN and a direct route share the same, tested logic.
package update

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Repo is the GitHub repository releases are taken from.
const Repo = "sedooj/netleash"

// Fetcher downloads a URL and returns its body.
type Fetcher func(url string) ([]byte, error)

// Release is what we need to know about the latest release.
type Release struct {
	Tag string `json:"tag_name"`
	URL string `json:"html_url"`
}

// Version is the tag without the leading "v".
func (r Release) Version() string { return strings.TrimPrefix(r.Tag, "v") }

// LatestURL is the API endpoint for the latest (non-pre-release, non-draft) release.
func LatestURL() string { return "https://api.github.com/repos/" + Repo + "/releases/latest" }

// AssetName is the release archive for a platform, e.g. netleash-darwin-arm64.tar.gz.
func AssetName(goos, goarch string) string { return fmt.Sprintf("netleash-%s-%s.tar.gz", goos, goarch) }

// Supported reports whether release archives are published for the platform.
func Supported(goos, goarch string) bool {
	switch goos + "/" + goarch {
	case "darwin/arm64", "linux/amd64", "linux/arm64":
		return true
	}
	return false
}

// DownloadURL is the URL of a release asset.
func DownloadURL(tag, asset string) string {
	return "https://github.com/" + Repo + "/releases/download/" + tag + "/" + asset
}

// Latest asks GitHub for the latest release.
func Latest(fetch Fetcher) (Release, error) {
	body, err := fetch(LatestURL())
	if err != nil {
		return Release{}, err
	}
	var r Release
	if err := json.Unmarshal(body, &r); err != nil || r.Tag == "" {
		return Release{}, errors.New("unexpected answer from GitHub")
	}
	return r, nil
}

// ChecksumFor extracts the SHA-256 of asset from the contents of a SHA256SUMS file ("<hex>  <name>" lines).
func ChecksumFor(sums []byte, asset string) (string, error) {
	for _, line := range strings.Split(string(sums), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == asset && len(f[0]) == 64 {
			return strings.ToLower(f[0]), nil
		}
	}
	return "", fmt.Errorf("no checksum for %s in SHA256SUMS", asset)
}

// Verify checks that data hashes to want (hex SHA-256).
func Verify(data []byte, want string) error {
	sum := sha256.Sum256(data)
	if got := hex.EncodeToString(sum[:]); got != strings.ToLower(want) {
		return fmt.Errorf("CHECKSUM MISMATCH (expected %s, got %s)", want, got)
	}
	return nil
}

// Download fetches the archive for tag, verifies it against SHA256SUMS and returns its bytes.
func Download(fetch Fetcher, tag, asset string) ([]byte, error) {
	archive, err := fetch(DownloadURL(tag, asset))
	if err != nil {
		return nil, err
	}
	sums, err := fetch(DownloadURL(tag, "SHA256SUMS"))
	if err != nil {
		return nil, err
	}
	want, err := ChecksumFor(sums, asset)
	if err != nil {
		return nil, err
	}
	if err := Verify(archive, want); err != nil {
		return nil, err
	}
	return archive, nil
}

// Extract unpacks a .tar.gz into dir, accepting only regular files and directories whose paths stay inside dir.
// Modes are preserved (the installer needs its executable bit).
func Extract(archive []byte, dir string) error {
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	root, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		clean := filepath.Clean(h.Name)
		if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return fmt.Errorf("unsafe path in archive: %q", h.Name)
		}
		target := filepath.Join(root, clean)
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_EXCL, os.FileMode(h.Mode)&0o755)
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, tr); err != nil { //nolint:gosec // size is bounded by the verified archive
				f.Close()
				return err
			}
			if err := f.Close(); err != nil {
				return err
			}
			_ = os.Chmod(target, os.FileMode(h.Mode)&0o755)
		default:
			return fmt.Errorf("unsupported entry type in archive: %q", h.Name)
		}
	}
}
