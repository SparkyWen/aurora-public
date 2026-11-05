package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestUnknownCommandReturnsUsage(t *testing.T) {
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	if code := run([]string{"unknown"}, stdout, stderr); code != 64 {
		t.Fatalf("code = %d, want 64", code)
	}
	if !strings.Contains(stderr.String(), "usage:") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestConfigArgumentsRejectUnexpectedValues(t *testing.T) {
	stderr := &bytes.Buffer{}
	if _, code := parseConfigArgs("sync", []string{"--config", "/tmp/config", "secret"}, stderr); code != 64 {
		t.Fatalf("code = %d, want 64", code)
	}
	if strings.Contains(stderr.String(), "read-secret") {
		t.Fatal("usage output leaked secret")
	}
}
