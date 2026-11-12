// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

package update

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func makeTar(t *testing.T, entries []tar.Header, bodies map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, h := range entries {
		h := h
		body := bodies[h.Name]
		h.Size = int64(len(body))
		if err := tw.WriteHeader(&h); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	tw.Close()
	gz.Close()
	return buf.Bytes()
}

func sumHex(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func TestLatestAndAsset(t *testing.T) {
	r, err := Latest(func(url string) ([]byte, error) {
		if url != LatestURL() {
			t.Errorf("unexpected URL %s", url)
		}
		return []byte(`{"tag_name":"v0.2.0","html_url":"https://example.invalid/r"}`), nil
	})
	if err != nil || r.Version() != "0.2.0" || r.URL == "" {
		t.Fatalf("got %+v, %v", r, err)
	}
	if got := AssetName("darwin", "arm64"); got != "netleash-darwin-arm64.tar.gz" {
		t.Errorf("asset name %q", got)
	}
	if _, err := Latest(func(string) ([]byte, error) { return []byte(`{}`), nil }); err == nil {
		t.Error("an answer without a tag must be an error")
	}
	if _, err := Latest(func(string) ([]byte, error) { return nil, errors.New("offline") }); err == nil {
		t.Error("fetch errors must propagate")
	}
}

func TestChecksumAndVerify(t *testing.T) {
	sums := []byte(strings.Repeat("a", 64) + "  other.tar.gz\n" + strings.Repeat("B", 64) + "  netleash-darwin-arm64.tar.gz\n")
	got, err := ChecksumFor(sums, "netleash-darwin-arm64.tar.gz")
	if err != nil || got != strings.Repeat("b", 64) {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := ChecksumFor(sums, "missing.tar.gz"); err == nil {
		t.Error("missing entry must be an error")
	}
	data := []byte("hello")
	if err := Verify(data, sumHex(data)); err != nil {
		t.Error(err)
	}
	if err := Verify([]byte("tampered"), sumHex(data)); err == nil {
		t.Error("a different content must fail verification")
	}
}

func TestDownloadRefusesTamperedArchive(t *testing.T) {
	good := []byte("archive-bytes")
	sums := []byte(sumHex(good) + "  " + AssetName("darwin", "arm64") + "\n")
	mk := func(archive []byte) Fetcher {
		return func(url string) ([]byte, error) {
			if strings.HasSuffix(url, "SHA256SUMS") {
				return sums, nil
			}
			return archive, nil
		}
	}
	if _, err := Download(mk(good), "v0.2.0", AssetName("darwin", "arm64")); err != nil {
		t.Fatalf("good archive rejected: %v", err)
	}
	if _, err := Download(mk([]byte("evil")), "v0.2.0", AssetName("darwin", "arm64")); err == nil {
		t.Fatal("a tampered archive must be refused")
	}
}

func TestExtract(t *testing.T) {
	arch := makeTar(t, []tar.Header{
		{Name: "netleash-darwin-arm64/", Typeflag: tar.TypeDir, Mode: 0o755},
		{Name: "netleash-darwin-arm64/install.sh", Typeflag: tar.TypeReg, Mode: 0o755},
		{Name: "netleash-darwin-arm64/Netleash.app/Contents/Info.plist", Typeflag: tar.TypeReg, Mode: 0o644},
	}, map[string]string{
		"netleash-darwin-arm64/install.sh":                       "#!/bin/sh\n",
		"netleash-darwin-arm64/Netleash.app/Contents/Info.plist": "<plist/>",
	})
	dir := t.TempDir()
	if err := Extract(arch, dir); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(dir, "netleash-darwin-arm64", "install.sh"))
	if err != nil || fi.Mode()&0o100 == 0 {
		t.Fatalf("installer missing or not executable: %v %v", fi, err)
	}
}

func TestExtractRejectsUnsafeArchives(t *testing.T) {
	for name, h := range map[string]tar.Header{
		"parent traversal": {Name: "../evil", Typeflag: tar.TypeReg, Mode: 0o644},
		"nested traversal": {Name: "a/../../evil", Typeflag: tar.TypeReg, Mode: 0o644},
		"absolute path":    {Name: "/etc/evil", Typeflag: tar.TypeReg, Mode: 0o644},
		"symlink":          {Name: "link", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd"},
	} {
		dir := t.TempDir()
		if err := Extract(makeTar(t, []tar.Header{h}, nil), dir); err == nil {
			t.Errorf("%s: must be rejected", name)
		}
		if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "evil")); err == nil {
			t.Errorf("%s: file escaped the target directory", name)
		}
	}
}

func TestSupportedPlatforms(t *testing.T) {
	for goos, archs := range map[string][]string{"darwin": {"arm64"}, "linux": {"amd64", "arm64"}} {
		for _, a := range archs {
			if !Supported(goos, a) {
				t.Errorf("%s/%s must be supported", goos, a)
			}
		}
	}
	for _, p := range [][2]string{{"darwin", "amd64"}, {"windows", "amd64"}, {"freebsd", "amd64"}, {"linux", "386"}} {
		if Supported(p[0], p[1]) {
			t.Errorf("%v must not be supported", p)
		}
	}
	if AssetName("linux", "amd64") != "netleash-linux-amd64.tar.gz" {
		t.Error("asset name")
	}
}
