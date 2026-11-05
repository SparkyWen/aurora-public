package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"aurora/edge-agent/internal/lease"
)

func TestKeygenCreatesNonOverwrittenPKCS8AndPublicMetadata(t *testing.T) {
	directory := t.TempDir()
	privatePath := filepath.Join(directory, "home-egress.pem")
	publicPath := filepath.Join(directory, "home-egress.pub.json")
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}

	code := run([]string{
		"keygen",
		"--private", privatePath,
		"--public", publicPath,
		"--key-id", "home-egress-1",
	}, stdout, stderr)
	if code != 0 {
		t.Fatalf("keygen code=%d stderr=%s", code, stderr.String())
	}
	privateInfo, err := os.Stat(privatePath)
	if err != nil {
		t.Fatal(err)
	}
	if privateInfo.Mode().Perm() != 0o600 {
		t.Fatalf("private mode = %o", privateInfo.Mode().Perm())
	}
	privateRaw, err := os.ReadFile(privatePath)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, err := lease.ParsePrivateKeyPKCS8(privateRaw)
	if err != nil {
		t.Fatal(err)
	}
	publicRaw, err := os.ReadFile(publicPath)
	if err != nil {
		t.Fatal(err)
	}
	var metadata struct {
		Algorithm string `json:"algorithm"`
		KeyID     string `json:"key_id"`
		PublicKey string `json:"public_key"`
	}
	if err := json.Unmarshal(publicRaw, &metadata); err != nil {
		t.Fatal(err)
	}
	decoded, err := base64.StdEncoding.Strict().DecodeString(metadata.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	if metadata.Algorithm != "ed25519" || metadata.KeyID != "home-egress-1" ||
		!bytes.Equal(decoded, privateKey.Public().(ed25519.PublicKey)) {
		t.Fatalf("invalid public metadata: %#v", metadata)
	}
	if strings.Contains(stdout.String(), metadata.PublicKey) || strings.Contains(stdout.String(), "PRIVATE KEY") {
		t.Fatal("keygen printed key material")
	}

	originalPrivate := append([]byte(nil), privateRaw...)
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{
		"keygen",
		"--private", privatePath,
		"--public", publicPath,
		"--key-id", "home-egress-1",
	}, stdout, stderr); code == 0 {
		t.Fatal("second keygen overwrote an existing trust root")
	}
	after, err := os.ReadFile(privatePath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, originalPrivate) {
		t.Fatal("existing private key changed")
	}
}

func TestUnknownCommandReturnsUsageWithoutSecrets(t *testing.T) {
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}

	if code := run([]string{"unknown"}, stdout, stderr); code != 64 {
		t.Fatalf("code = %d, want 64", code)
	}
	if !strings.Contains(stderr.String(), "usage:") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}
