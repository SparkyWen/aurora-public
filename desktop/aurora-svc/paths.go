package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
)

// Paths are every filesystem location the service touches. All of them are
// machine-wide by construction — see [resolvePaths].
type Paths struct {
	StateDir   string // %ProgramData%\Aurora
	RunDir     string // %ProgramData%\Aurora\run      — SYSTEM-only, holds config.json + cache.db
	ConfigPath string // %ProgramData%\Aurora\run\config.json
	TokenPath  string // %ProgramData%\Aurora\svc-token
	LogPath    string // %ProgramData%\Aurora\logs\sing-box.log
	SingBox    string // <install dir>\sing-box.exe
}

// resolvePaths derives every shared location from MACHINE-WIDE environment only.
//
// This is the fix for "aurora-svc start failed (403) config path outside allowed
// dir": this process runs as LocalSystem while the Flutter app runs as the
// logged-in user, so %APPDATA% (and %USERPROFILE%, %LOCALAPPDATA%, %TEMP%, …)
// expand to two different directories in the two processes. Anything agreed
// between them that is derived from a per-user variable is guaranteed to
// disagree. %ProgramData% is identical in both contexts; it is the only kind of
// variable allowed here. Adding a per-user lookup below re-introduces the bug —
// TestResolvePathsNeverReadsPerUserEnv guards it.
func resolvePaths(getenv func(string) string, exeDir string) Paths {
	base := ""
	for _, key := range []string{"ProgramData", "ALLUSERSPROFILE"} {
		if v := strings.TrimSpace(getenv(key)); v != "" {
			base = filepath.Join(v, "Aurora")
			break
		}
	}
	if base == "" {
		base = defaultStateBase(exeDir)
	}
	run := filepath.Join(base, "run")
	return Paths{
		StateDir:   base,
		RunDir:     run,
		ConfigPath: filepath.Join(run, "config.json"),
		TokenPath:  filepath.Join(base, "svc-token"),
		LogPath:    filepath.Join(base, "logs", "sing-box.log"),
		SingBox:    filepath.Join(exeDir, singBoxBinary),
	}
}

// exeDir is the directory the service binary was installed into; the bundled
// sing-box sits next to it.
func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return filepath.Dir(exe)
}

// fileToken reads the shared bearer token from disk on EVERY call.
//
// Caching it at startup is a bug: the service starts at boot, the token can be
// (re)provisioned afterwards by an install or a repair, and a service holding
// the pre-provisioning value answers 401 to a perfectly correct app until the
// machine reboots. The file is a few dozen bytes and the app polls at 1 Hz.
func fileToken(path string) func() string {
	return func() string {
		b, err := os.ReadFile(path)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
}

// ensureToken provisions the shared bearer token if it is not there yet and
// returns it. The privileged side owns this credential: it is the only party
// guaranteed to exist before the app's first request, and a single writer means
// the app can never race a rotation against the service.
func ensureToken(path string) (string, error) {
	if b, err := os.ReadFile(path); err == nil {
		if tok := strings.TrimSpace(string(b)); tok != "" {
			return tok, nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	tok := hex.EncodeToString(buf)
	if err := os.WriteFile(path, []byte(tok), 0o600); err != nil {
		return "", err
	}
	// The app runs unelevated and must be able to read it; everything else on
	// the box must not be able to rewrite it.
	hardenTokenFile(path)
	return tok, nil
}
