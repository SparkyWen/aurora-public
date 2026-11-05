package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// ---- helpers --------------------------------------------------------------

// fakeSingBox writes a shell stand-in for sing-box.exe so the runner's process
// lifecycle can be exercised without the real binary. Unix-only: the Go tests
// run on the macOS/Linux dev boxes, the Windows build is compile-checked.
func fakeSingBox(t *testing.T, script string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell stand-in is unix-only")
	}
	p := filepath.Join(t.TempDir(), "fake-sing-box")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

// settle is how long start() waits before calling a launch good. Tests that
// assert on what the child DID need a window wider than process-spawn latency
// (~650ms for a freshly-written script on macOS); tests that only care about
// process identity keep it short.
func testRunner(t *testing.T, singbox string, settle time.Duration) *Runner {
	t.Helper()
	dir := t.TempDir()
	return &Runner{
		SingBoxPath: singbox,
		WorkDir:     filepath.Join(dir, "run"),
		ConfigPath:  filepath.Join(dir, "run", "config.json"),
		LogPath:     filepath.Join(dir, "logs", "sing-box.log"),
		SettleDelay: settle,
		// Hermetic by default. A nil TunnelExists/TunnelGone falls through to
		// the real net.Interfaces() lookup — and the machine that runs this
		// suite may itself be a daily Aurora client. When it is connected, a REAL
		// aurora0 interface exists on this box, and every test below that reaches
		// preflight would start failing via its stale-adapter refusal for a
		// reason that has nothing to do with the behaviour under test. Tests
		// that specifically exercise the tunnel-gone wait or the stale-adapter
		// refusal install their own stub, overriding these no-ops.
		TunnelExists: func(string) bool { return false },
		TunnelGone:   func(string, time.Duration) {},
	}
}

const (
	shortSettle = 250 * time.Millisecond
	wideSettle  = 3 * time.Second
)

func staticGuard(token string) *Guard {
	return &Guard{TokenSource: func() string { return token }}
}

// ---- root cause: the shared directory must not come from a per-user var ----

// THE regression test for "aurora-svc start failed (403) config path outside
// allowed dir". The service runs as LocalSystem; the app runs as the logged-in
// user. %APPDATA% (and every other per-user variable) therefore resolves to two
// different directories in the two processes, so any location derived from one
// can never be the location the other means. Machine-wide variables only.
func TestResolvePathsNeverReadsPerUserEnv(t *testing.T) {
	var asked []string
	getenv := func(k string) string {
		asked = append(asked, k)
		if k == "ProgramData" {
			return `C:\ProgramData`
		}
		return ""
	}
	p := resolvePaths(getenv, `C:\Program Files\Aurora`)

	for _, k := range asked {
		switch strings.ToUpper(k) {
		case "APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "TEMP", "TMP", "USERNAME":
			t.Fatalf("resolvePaths consulted per-user variable %q — "+
				"the service and the app would resolve different directories", k)
		}
	}
	want := filepath.Join(`C:\ProgramData`, "Aurora")
	for _, got := range []string{p.StateDir, p.RunDir, p.ConfigPath, p.TokenPath, p.LogPath} {
		if !strings.HasPrefix(got, want) {
			t.Fatalf("%q is not under the machine-wide state dir %q", got, want)
		}
	}
	if p.SingBox != filepath.Join(`C:\Program Files\Aurora`, singBoxBinary) {
		t.Fatalf("sing-box must sit next to the service binary, got %q", p.SingBox)
	}
}

func TestResolvePathsFallsBackToAllUsersProfile(t *testing.T) {
	getenv := func(k string) string {
		if k == "ALLUSERSPROFILE" {
			return `C:\ProgramData`
		}
		return ""
	}
	p := resolvePaths(getenv, `C:\Program Files\Aurora`)
	if !strings.HasPrefix(p.StateDir, filepath.Join(`C:\ProgramData`, "Aurora")) {
		t.Fatalf("want ALLUSERSPROFILE fallback, got %q", p.StateDir)
	}
}

func TestResolvePathsLastResortStaysNextToTheBinary(t *testing.T) {
	if runtime.GOOS == "linux" {
		// Linux never falls back to a directory derived from the binary path —
		// defaultStateBase is hard-coded to /var/lib/aurora regardless of
		// exeDir (see TestResolvePathsOnLinuxNeverReadsPerUserEnv). This
		// fallback-beside-the-binary behaviour is the !linux (paths_other.go)
		// story only.
		t.Skip("linux has a fixed state dir, not a binary-relative fallback")
	}
	p := resolvePaths(func(string) string { return "" }, "/opt/aurora")
	if !strings.HasPrefix(p.StateDir, "/opt/aurora") {
		t.Fatalf("want a fallback under the binary dir, got %q", p.StateDir)
	}
}

// ---- Linux: same cross-privilege-boundary trap, different variable names --

// Linux has no %ProgramData%; the equivalent bug there is deriving the shared
// directory from $HOME (or $XDG_*, $TMPDIR) — the service runs as root, the
// GUI as the logged-in user, so those resolve to two different places just
// like %APPDATA% did on Windows.
func TestResolvePathsOnLinuxNeverReadsPerUserEnv(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("linux-only path policy")
	}
	var asked []string
	getenv := func(k string) string {
		asked = append(asked, k)
		return ""
	}
	p := resolvePaths(getenv, "/opt/aurora")
	for _, k := range asked {
		switch strings.ToUpper(k) {
		case "HOME", "USER", "USERNAME", "XDG_STATE_HOME", "XDG_DATA_HOME",
			"XDG_RUNTIME_DIR", "TMPDIR":
			t.Fatalf("resolvePaths consulted per-user variable %q", k)
		}
	}
	if p.StateDir != "/var/lib/aurora" {
		t.Fatalf("want the machine-wide state dir, got %q", p.StateDir)
	}
	if p.SingBox != "/opt/aurora/sing-box" {
		t.Fatalf("sing-box must sit next to the service binary, got %q", p.SingBox)
	}
}

// ---- token: read per request, never cached at startup ---------------------

func TestFileTokenIsReReadPerRequest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "svc-token")
	if err := os.WriteFile(path, []byte("first\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	g := &Guard{TokenSource: fileToken(path)}

	if !g.authorize(bearer("first")) {
		t.Fatal("expected the on-disk token to authorize")
	}
	// The credential is provisioned by whoever starts first and may be rotated
	// while the service is alive; a token cached at startup answers 401 forever.
	if err := os.WriteFile(path, []byte("second"), 0o600); err != nil {
		t.Fatal(err)
	}
	if g.authorize(bearer("first")) {
		t.Fatal("expected the rotated-away token to be rejected")
	}
	if !g.authorize(bearer("second")) {
		t.Fatal("expected the rotated-in token to authorize")
	}
}

func TestAuthorizeRejectsMissingOrWrongToken(t *testing.T) {
	g := staticGuard("secret")
	if g.authorize(httptest.NewRequest(http.MethodPost, "/start", nil)) {
		t.Fatal("expected reject without Authorization header")
	}
	if g.authorize(bearer("nope")) {
		t.Fatal("expected reject with wrong token")
	}
	if !g.authorize(bearer("secret")) {
		t.Fatal("expected accept with right token")
	}
}

func TestAuthorizeRejectsWhenNoTokenIsProvisioned(t *testing.T) {
	g := staticGuard("")
	if g.authorize(bearer("")) {
		t.Fatal("expected reject when no token is provisioned")
	}
}

func TestEnsureTokenCreatesOnceAndKeepsIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "aurora", "svc-token")
	first, err := ensureToken(path)
	if err != nil {
		t.Fatalf("ensureToken: %v", err)
	}
	if len(first) < 32 {
		t.Fatalf("token too short: %q", first)
	}
	second, err := ensureToken(path)
	if err != nil {
		t.Fatalf("ensureToken (second): %v", err)
	}
	if second != first {
		t.Fatal("ensureToken must not rotate an existing token out from under the app")
	}
}

// ---- /start now carries the config itself, never a path -------------------

func TestStartRejectsMissingConfig(t *testing.T) {
	s := &server{guard: staticGuard("tok"), runner: &Runner{}}
	rec := post(t, s, `{}`, "tok")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400 for a body with no config, got %d (%s)", rec.Code, rec.Body)
	}
}

func TestStartRejectsNonJSONConfig(t *testing.T) {
	s := &server{guard: staticGuard("tok"), runner: &Runner{}}
	rec := post(t, s, `{"config":"not json at all"}`, "tok")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400 for a config that is not JSON, got %d", rec.Code)
	}
}

func TestStartUnauthorized(t *testing.T) {
	s := &server{guard: staticGuard("tok"), runner: &Runner{}}
	rec := post(t, s, `{"config":"{}"}`, "wrong")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

// A config sing-box rejects must become a quotable reason before the child is
// ever started, instead of a 200 followed by silence 1.2s later.
func TestStartRejectsAConfigTheCoreCannotParse(t *testing.T) {
	// `sing-box check`'s stand-in: when "check" shows up in argv, fail with the
	// reason; any other invocation (i.e. "run") would hang, proving it was
	// never reached.
	sb := fakeSingBox(t, `
case "$1" in
  check) echo "FATAL decode config: unknown field bogus" >&2; exit 1 ;;
  *) sleep 30 ;;
esac`)
	rn := testRunner(t, sb, shortSettle)
	err := rn.start([]byte(`{"bogus":1}`))
	if err == nil {
		t.Fatal("want a rejection, got nil")
	}
	if !strings.Contains(err.Error(), "unknown field bogus") {
		t.Fatalf("the core's own words must survive to the caller, got %q", err)
	}
	if rn.pid() != 0 {
		t.Fatal("a config that failed check must never be handed to run")
	}
}

func TestStartReportsAMissingRequiredFile(t *testing.T) {
	sb := fakeSingBox(t, `sleep 30`)
	rn := testRunner(t, sb, shortSettle)
	rn.RequiredFiles = []string{filepath.Join(t.TempDir(), "wintun.dll")}
	err := rn.start([]byte(`{"log":{}}`))
	if err == nil || !strings.Contains(err.Error(), "wintun.dll") {
		t.Fatalf("want the missing file named, got %v", err)
	}
}

func TestStartWritesTheConfigIntoTheServiceOwnedDir(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 5 ;;
esac`), shortSettle)
	s := &server{guard: staticGuard("tok"), runner: rn}
	defer rn.stop()

	cfg := `{"log":{"level":"info"}}`
	rec := post(t, s, `{"config":`+jsonString(cfg)+`}`, "tok")
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (%s)", rec.Code, rec.Body)
	}
	got, err := os.ReadFile(rn.ConfigPath)
	if err != nil {
		t.Fatalf("config was not written where the service runs it from: %v", err)
	}
	if string(got) != cfg {
		t.Fatalf("config bytes differ: %q", got)
	}
}

// Fix round 1, finding 2: nothing pinned the /start wire format. Every
// readiness test above calls rn.startWithProbe(...) with a Go-constructed
// *clashProbe, bypassing JSON entirely — encoding/json silently ignores
// unknown fields and leaves an absent pointer nil, so a Dart/Go field-name
// mismatch on "clash_probe"/"port"/"secret" would NOT error. It would just
// silently fall back to the legacy fixed-delay path and look like it worked
// on both sides while quietly not delivering this fix. These two tests go
// through handleStart with a real JSON body so a rename breaks the build,
// not a user's machine.
func TestHandleStartParsesClashProbeFromJSON(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 30 ;;
esac`), 0)
	rn.ReadyTimeout = 2 * time.Second
	var gotPort int
	var gotSecret string
	rn.ClashPing = func(port int, secret string) bool {
		gotPort, gotSecret = port, secret
		return true // answer immediately so the test does not wait out a tick
	}
	s := &server{guard: staticGuard("tok"), runner: rn}
	defer rn.stop()

	body := `{"config":` + jsonString(`{"log":{}}`) + `,"clash_probe":{"port":9999,"secret":"deadbeef"}}`
	rec := post(t, s, body, "tok")
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (%s)", rec.Code, rec.Body)
	}
	if gotPort != 9999 || gotSecret != "deadbeef" {
		t.Fatalf("clash_probe did not reach the runner as sent over JSON: port=%d secret=%q", gotPort, gotSecret)
	}
}

func TestHandleStartWithoutClashProbeTakesTheLegacyPath(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 30 ;;
esac`), shortSettle)
	pingCalled := false
	rn.ClashPing = func(int, string) bool { pingCalled = true; return true }
	s := &server{guard: staticGuard("tok"), runner: rn}
	defer rn.stop()

	body := `{"config":` + jsonString(`{"log":{}}`) + `}`
	rec := post(t, s, body, "tok")
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d (%s)", rec.Code, rec.Body)
	}
	if pingCalled {
		t.Fatal("a body with no clash_probe must take the legacy settle-delay path, not poll the Clash API")
	}
	if rn.pid() == 0 {
		t.Fatal("child should be running")
	}
}

// ---- runner ---------------------------------------------------------------

// A config sing-box refuses is the single most likely failure after a fresh
// install. Reporting a bare "exit status 1" leaves the user with a red dot and
// nothing to act on, so the start must fail loudly with the core's own words.
func TestRunnerSurfacesAnImmediateExitWithOutput(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) echo "FATAL: decode config: bad json" >&2; exit 1 ;;
esac`), wideSettle)
	err := rn.start([]byte(`{}`))
	if err == nil {
		t.Fatal("want an error when sing-box dies on startup")
	}
	if !strings.Contains(err.Error(), "decode config: bad json") {
		t.Fatalf("error must quote sing-box's own output, got %q", err)
	}
	state, detail := rn.state()
	if state != "error" || !strings.Contains(detail, "decode config: bad json") {
		t.Fatalf("status must keep the reason, got %q / %q", state, detail)
	}
	if b, err := os.ReadFile(rn.LogPath); err != nil ||
		!strings.Contains(string(b), "decode config") {
		t.Fatalf("sing-box output must land in the log file (%v): %s", err, b)
	}
}

func TestRunnerIsIdempotentForTheSameConfig(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 5 ;;
esac`), shortSettle)
	defer rn.stop()
	cfg := []byte(`{"log":{"level":"info"}}`)
	if err := rn.start(cfg); err != nil {
		t.Fatalf("first start: %v", err)
	}
	first := rn.pid()
	if err := rn.start(cfg); err != nil {
		t.Fatalf("second start: %v", err)
	}
	if rn.pid() != first {
		t.Fatal("an identical config must not churn the tunnel")
	}
}

func TestRunnerRestartsWhenTheConfigChanges(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 5 ;;
esac`), shortSettle)
	defer rn.stop()
	if err := rn.start([]byte(`{"log":{"level":"info"}}`)); err != nil {
		t.Fatalf("first start: %v", err)
	}
	first := rn.pid()
	next := []byte(`{"log":{"level":"debug"}}`)
	if err := rn.start(next); err != nil {
		t.Fatalf("second start: %v", err)
	}
	if rn.pid() == first {
		t.Fatal("a changed config must be applied, not silently ignored")
	}
	got, err := os.ReadFile(rn.ConfigPath)
	if err != nil || !bytes.Equal(got, next) {
		t.Fatalf("the new config must be on disk (%v): %s", err, got)
	}
}

func TestRunnerStopIsSafeWhenNothingRuns(t *testing.T) {
	rn := testRunner(t, "/nonexistent/sing-box", shortSettle)
	rn.stop()
	if state, _ := rn.state(); state != "stopped" {
		t.Fatalf("want stopped, got %q", state)
	}
}

func TestRunnerStartFailsWhenTheBinaryIsMissing(t *testing.T) {
	rn := testRunner(t, filepath.Join(t.TempDir(), "sing-box-that-is-not-there"), shortSettle)
	if err := rn.start([]byte(`{}`)); err == nil {
		t.Fatal("want an error when sing-box.exe is missing from the bundle")
	}
	if state, detail := rn.state(); state != "error" || detail == "" {
		t.Fatalf("want an error state with a reason, got %q / %q", state, detail)
	}
}

// sing-box resolves cache_file and other relative paths against its working
// directory. Inheriting the service's cwd would drop cache.db into
// C:\Windows\System32, so the child must be pinned to the state dir.
func TestRunnerPinsTheChildWorkingDirectory(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) pwd > cwd.txt; sleep 5 ;;
esac`), wideSettle)
	defer rn.stop()
	if err := rn.start([]byte(`{}`)); err != nil {
		t.Fatalf("start: %v", err)
	}
	b, err := os.ReadFile(filepath.Join(rn.WorkDir, "cwd.txt"))
	if err != nil {
		t.Fatalf("child did not run in WorkDir: %v", err)
	}
	got, err := filepath.EvalSymlinks(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(rn.WorkDir)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("child cwd = %q, want %q", got, want)
	}
}

// ---- readiness: replaces the fixed 1.2s settle delay ----------------------

func TestAwaitReadyReturnsTheCoreLastWordsWhenItDiesLate(t *testing.T) {
	// Survives the settle window, then dies: on Windows, creating the wintun
	// adapter and installing routes and WFP rules takes seconds, so failures
	// often happen after the 1.2s mark.
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 1; echo "FATAL create tun: access denied" >&2; exit 1 ;;
esac`)
	rn := testRunner(t, sb, 0)
	rn.ReadyTimeout = 5 * time.Second
	rn.ClashPing = func(int, string) bool { return false }
	err := rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"})
	if err == nil || !strings.Contains(err.Error(), "access denied") {
		t.Fatalf("want the core's late failure quoted, got %v", err)
	}
}

// Fix round 1, finding 1: awaitReady drains `exited`'s one buffered value to
// learn the child died; stopLocked must NOT then re-select on that same
// (now permanently empty) channel expecting a reap signal — nothing will
// ever arrive, so it would burn its whole 5s fallback on every fast-failure
// path, every time, deterministically. This is exactly the scenario the
// readiness wait exists to serve, so it must return fast.
func TestAwaitReadyDeathDoesNotBurnTheReapBudget(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 1; echo "FATAL create tun: access denied" >&2; exit 1 ;;
esac`)
	rn := testRunner(t, sb, 0)
	rn.ReadyTimeout = 5 * time.Second
	rn.ClashPing = func(int, string) bool { return false }
	started := time.Now()
	err := rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"})
	elapsed := time.Since(started)
	if err == nil || !strings.Contains(err.Error(), "access denied") {
		t.Fatalf("want the core's late failure quoted, got %v", err)
	}
	// The child dies at ~1s; process-spawn overhead adds a few hundred ms.
	// 3s leaves ample headroom above that while staying far under the 5s
	// reap-fallback this test exists to prove we no longer pay.
	if elapsed > 3*time.Second {
		t.Fatalf("startWithProbe took %s — stopLocked must have re-waited on "+
			"the already-drained exited channel instead of trusting awaitReady's proof", elapsed)
	}
}

func TestAwaitReadySucceedsAsSoonAsTheApiAnswers(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 30 ;;
esac`)
	rn := testRunner(t, sb, 0)
	rn.ReadyTimeout = 5 * time.Second
	var pings int
	rn.ClashPing = func(int, string) bool { pings++; return pings > 1 }
	started := time.Now()
	if err := rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"}); err != nil {
		t.Fatalf("want success once the API answers, got %v", err)
	}
	if time.Since(started) > 3*time.Second {
		t.Fatal("must return as soon as the API answers, not burn the whole budget")
	}
	rn.stop()
}

func TestStartWithoutAProbeKeepsTheOldSettleBehaviour(t *testing.T) {
	// Old app with a new service: with no clash_probe, fall back to the
	// "process is still alive" criterion.
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 30 ;;
esac`)
	rn := testRunner(t, sb, shortSettle)
	if err := rn.start([]byte(`{"log":{}}`)); err != nil {
		t.Fatalf("want the legacy path to still work, got %v", err)
	}
	if rn.pid() == 0 {
		t.Fatal("child should be running")
	}
	rn.stop()
}

func TestAwaitReadyTimesOutWithTheLogTail(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) echo "listening on tun"; sleep 30 ;;
esac`)
	rn := testRunner(t, sb, 0)
	rn.ReadyTimeout = 700 * time.Millisecond
	rn.ClashPing = func(int, string) bool { return false }
	err := rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"})
	if err == nil || !strings.Contains(err.Error(), "tunnel_not_ready") {
		t.Fatalf("want a named timeout, got %v", err)
	}
	rn.stop()
}

// ---- readiness: the budget must outlast a Windows adapter install ----------

// singBoxOpenInterfaceWarning mirrors sing-box's own C.StartTimeout. When the
// TUN inbound's "open interface" step runs past it, sing-box logs
// `open interface take too much time to finish!` — a WARNING from its
// taskmonitor, after which it KEEPS WAITING. On Windows that step is
// wintun.CreateAdapter, i.e. a device install: SetupAPI + several 10s registry
// waits inside wintun.dll, routinely slower than this on a cold machine or one
// with security software hooking device installs.
const singBoxOpenInterfaceWarning = 10 * time.Second

// The 2026-08-05 Windows report, in one assertion. The budget was 12s, so it
// expired TWO SECONDS into sing-box's own "slow but still working" window and
// killed a core that was still creating the wintun adapter — a start that used
// to succeed (before v1.0.10 replaced the 1.2s settle delay with this
// handshake, /start never waited for readiness at all, so a slow adapter was
// invisible). Whatever this number becomes, it must leave real room past the
// point where sing-box itself is merely warning.
func TestReadyBudgetOutlastsSingBoxOwnSlowStartWarning(t *testing.T) {
	if defaultReadyTimeout < 4*singBoxOpenInterfaceWarning {
		t.Fatalf("default readiness budget is %s; sing-box only WARNS at %s and "+
			"keeps opening the interface, so anything close to that kills cores "+
			"that were still coming up", defaultReadyTimeout, singBoxOpenInterfaceWarning)
	}
}

// Giving up is not the same failure as the core rejecting the config or losing
// the controller port, and the user's next move differs. When the tail shows
// the TUN interface never came up, say so in a token the app can match on.
func TestReadyTimeoutSaysTheInterfaceNeverCameUp(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) echo "warn inbound/tun[tun-in]: open interface take too much time to finish!"; sleep 30 ;;
esac`)
	rn := testRunner(t, sb, 0)
	rn.ReadyTimeout = 700 * time.Millisecond
	rn.ClashPing = func(int, string) bool { return false }
	err := rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"})
	if err == nil || !strings.Contains(err.Error(), tunInterfaceNeverUpToken) {
		t.Fatalf("want the interface named as what never came up, got %v", err)
	}
	rn.stop()
}

// The opposite half: the interface DID come up and something else (a taken
// controller port, a wedged core) kept the API from answering. Blaming the
// adapter there would send the user to reboot over a problem a reboot cannot
// fix.
func TestReadyTimeoutDoesNotBlameTheInterfaceWhenItCameUp(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) echo "info inbound/tun[tun-in]: started at aurora0"; sleep 30 ;;
esac`)
	rn := testRunner(t, sb, 0)
	rn.ReadyTimeout = 700 * time.Millisecond
	rn.ClashPing = func(int, string) bool { return false }
	err := rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"})
	if err == nil || !strings.Contains(err.Error(), "tunnel_not_ready") {
		t.Fatalf("want a named timeout, got %v", err)
	}
	if strings.Contains(err.Error(), tunInterfaceNeverUpToken) {
		t.Fatalf("the interface came up; the timeout must not blame it: %v", err)
	}
	rn.stop()
}

// startInFlight launches a start against a child that never becomes ready and
// returns once the child is demonstrably running, so a test can act WHILE the
// readiness wait is in progress. It deliberately polls tailString(), which is
// lock-free: everything else about the runner is behind rn.mu, and rn.mu is
// exactly what /start holds for the whole wait.
func startInFlight(t *testing.T, rn *Runner) <-chan error {
	t.Helper()
	done := make(chan error, 1)
	go func() {
		done <- rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"})
	}()
	deadline := time.Now().Add(10 * time.Second)
	for !strings.Contains(rn.tailString(), "RUNNING") {
		if time.Now().After(deadline) {
			t.Fatal("the fake core never reported itself running")
		}
		time.Sleep(20 * time.Millisecond)
	}
	return done
}

// exec, not a plain `sleep`: the tests below time how long a stop takes, and a
// shell that outlives its own exec keeps the stdout pipe open through its
// still-running grandchild, so cmd.Wait() — and with it stopLocked's reap —
// would sit out its full fallback for a reason that has nothing to do with the
// behaviour under test. Real sing-box has no such grandchild.
const slowCore = `
case "$1" in
  check) exit 0 ;;
  *) echo RUNNING; exec sleep 30 ;;
esac`

// A readiness wait long enough to survive a Windows adapter install is also
// long enough to freeze the app if /status queues behind it: AuroraBridgeSvc's
// poller reads a 3s timeout as "the service died" and flips the UI to error,
// and desktop_shell's tray/status calls have no timeout at all.
func TestStatusAnswersWhileAStartIsStillWaitingForTheTunnel(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, slowCore), 0)
	rn.ReadyTimeout = 3 * time.Second
	rn.ClashPing = func(int, string) bool { return false }
	done := startInFlight(t, rn)
	defer func() { <-done }()

	s := &server{guard: staticGuard("tok"), runner: rn}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status", nil)
	req.Header.Set("Authorization", "Bearer tok")
	asked := time.Now()
	s.routes().ServeHTTP(rec, req)
	if took := time.Since(asked); took > time.Second {
		t.Fatalf("/status waited %s — it queued behind the start lock", took)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("bad json: %v", err)
	}
	if body["state"] != "starting" {
		t.Fatalf("a launched child is not ready yet, got %q", body["state"])
	}
	if body["detail"] != "" {
		t.Fatalf("a start in progress is not a failure; detail must stay empty, got %q", body["detail"])
	}
}

// Same reason from the other side: the Windows SCM's stop handler calls
// runner.stop() directly, and a stop that queued behind a 45s readiness wait
// would hang service shutdown (and the watchdog's stop→connect self-heal).
func TestStopAbortsAStartThatIsStillWaitingForTheTunnel(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, slowCore), 0)
	rn.ReadyTimeout = 30 * time.Second // only an abort can end this in time
	rn.ClashPing = func(int, string) bool { return false }
	done := startInFlight(t, rn)

	s := &server{guard: staticGuard("tok"), runner: rn}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/stop", nil)
	req.Header.Set("Authorization", "Bearer tok")
	asked := time.Now()
	s.routes().ServeHTTP(rec, req)
	if took := time.Since(asked); took > 3*time.Second {
		t.Fatalf("/stop waited %s — it queued behind the readiness wait", took)
	}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "start_cancelled") {
			t.Fatalf("want the aborted start to say so, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the readiness wait ignored the stop")
	}
	if pid := rn.pid(); pid != 0 {
		t.Fatalf("child %d survived the stop", pid)
	}
}

// The readiness wait is not the only part of a launch that holds the lock:
// preflight runs `sing-box check` first, and that alone gets 5s. An abort armed
// only around the wait would leave every stop that lands in THAT window queueing
// behind the whole launch, which is the same freeze in a narrower doorway.
func TestStopAbortsAStartThatIsStillInPreflight(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "checking")
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) touch `+marker+`; sleep 2; exit 0 ;;
  *) echo RUNNING; exec sleep 30 ;;
esac`), 0)
	rn.CheckTimeout = 10 * time.Second
	rn.ReadyTimeout = 30 * time.Second
	rn.ClashPing = func(int, string) bool { return false }

	done := make(chan error, 1)
	go func() {
		done <- rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"})
	}()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("preflight never reached `sing-box check`")
		}
		time.Sleep(20 * time.Millisecond)
	}

	s := &server{guard: staticGuard("tok"), runner: rn}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/stop", nil)
	req.Header.Set("Authorization", "Bearer tok")
	asked := time.Now()
	s.routes().ServeHTTP(rec, req)
	// Bounded by what is left of preflight, NOT by the readiness budget the
	// launch would have gone on to wait out.
	if took := time.Since(asked); took > 8*time.Second {
		t.Fatalf("/stop waited %s — the abort did not cover the preflight window", took)
	}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "start_cancelled") {
			t.Fatalf("want the aborted start to say so, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the launch ignored a stop that arrived during preflight")
	}
}

// ---- tunnel teardown: stop must wait for the adapter, not just the process -

// cmd.Wait() returning only proves the process was reaped; on Windows the
// wintun adapter is removed after that, and the watchdog's self-heal
// (stop → connect) is exactly the sequence that races it. stop() must wait
// for the interface itself to disappear, not just the child.
func TestStopWaitsForTheTunnelToActuallyGoAway(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 30 ;;
esac`)
	rn := testRunner(t, sb, shortSettle)
	var waited []string
	rn.TunnelGone = func(name string, _ time.Duration) { waited = append(waited, name) }
	if err := rn.start([]byte(`{"log":{}}`)); err != nil {
		t.Fatal(err)
	}
	rn.stop()
	// Process exit != adapter gone. Without waiting, the next start races the
	// adapter that has not disappeared yet for the device; the watchdog's
	// self-heal stop->connect has exactly this timing.
	if len(waited) != 1 || waited[0] != auroraTunInterfaceName {
		t.Fatalf("stop must wait for %q, waited=%v", auroraTunInterfaceName, waited)
	}
}

// An adapter left behind by an instance we no longer track must NOT block the
// start. Refusing was the intermittent-500 report ("sometimes 500, reconnecting fixes it"): nothing else on the
// machine ever removes an aurora0, and the start we were refusing to make is
// exactly what clears it (wintun sweeps orphaned devices on CreateAdapter,
// sing-tun falls back to OpenAdapter on ErrExist), so the refusal made one
// dirty teardown permanent instead of self-healing.
func TestPreflightStartsOverAnOrphanedAdapter(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) sleep 30 ;;
esac`)
	rn := testRunner(t, sb, shortSettle)
	rn.TunnelExists = func(string) bool { return true }
	if err := rn.start([]byte(`{"log":{}}`)); err != nil {
		t.Fatalf("an orphaned adapter must not block a start, got %v", err)
	}
	defer rn.stop()
	if !rn.staleAdapter {
		t.Fatal("starting over an orphan must be remembered")
	}
}

// ...and when such a start DOES fail, the failure has to say it began from a
// dirty slate — that is the difference between "retry" and "reboot".
func TestAFailedStartOverAnOrphanNamesTheWreckage(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) echo "boom" >&2; exit 1 ;;
esac`)
	rn := testRunner(t, sb, wideSettle)
	rn.TunnelExists = func(string) bool { return true }
	err := rn.start([]byte(`{"log":{}}`))
	if err == nil || !strings.Contains(err.Error(), staleAdapterToken) {
		t.Fatalf("want %q in the failure, got %v", staleAdapterToken, err)
	}
}

// A clean start must not inherit the tag from an earlier dirty one.
func TestACleanStartDoesNotClaimAnOrphan(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) echo "boom" >&2; exit 1 ;;
esac`)
	rn := testRunner(t, sb, wideSettle)
	stale := true
	rn.TunnelExists = func(string) bool { return stale }
	if err := rn.start([]byte(`{"log":{}}`)); err == nil {
		t.Fatal("want the first start to fail")
	}
	stale = false
	err := rn.start([]byte(`{"log":{}}`))
	if err == nil || strings.Contains(err.Error(), staleAdapterToken) {
		t.Fatalf("a clean slate must not be tagged, got %v", err)
	}
}

// ---- /status --------------------------------------------------------------

func TestStatusReportsStoppedForAFreshRunner(t *testing.T) {
	s := &server{guard: staticGuard("tok"), runner: &Runner{}}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status", nil)
	req.Header.Set("Authorization", "Bearer tok")
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("bad json: %v", err)
	}
	if body["state"] != "stopped" {
		t.Fatalf("want stopped, got %q", body["state"])
	}
}

func TestStatusCarriesTheFailureDetail(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) echo "listen tcp 127.0.0.1:9090: bind: address already in use" >&2; exit 1 ;;
esac`), wideSettle)
	_ = rn.start([]byte(`{}`))
	s := &server{guard: staticGuard("tok"), runner: rn}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status", nil)
	req.Header.Set("Authorization", "Bearer tok")
	s.routes().ServeHTTP(rec, req)

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("bad json: %v", err)
	}
	if body["state"] != "error" {
		t.Fatalf("want error, got %q", body["state"])
	}
	if !strings.Contains(body["detail"], "address already in use") {
		t.Fatalf("detail must carry the reason, got %q", body["detail"])
	}
}

// ---- ANSI stripping: sing-box colourises assuming a terminal, an app dialog
// is not one (Defect 1, reproduced live 2026-08-03) -------------------------

func TestTailBufferStringStripsANSI(t *testing.T) {
	tb := newTailBuffer(1024)
	if _, err := tb.Write([]byte("\x1b[31mFATAL\x1b[0m boom")); err != nil {
		t.Fatal(err)
	}
	if got := tb.String(); got != "FATAL boom" {
		t.Fatalf("tailBuffer.String() = %q, want %q", got, "FATAL boom")
	}
}

// Pins the exact repro from Defect 1: `sing-box check` rejecting a config
// with an unknown outbound type, colourised the way logrus-style loggers do.
// The colour must not survive into the error the app turns into a dialog.
func TestPreflightStripsANSIFromSingBoxCheckOutput(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) printf '\033[31mFATAL\033[0m[0000] decode config at /var/lib/aurora/run/config.json: outbounds[0]: unknown outbound type: nonexistent_proto\n' >&2; exit 1 ;;
  *) sleep 30 ;;
esac`)
	rn := testRunner(t, sb, shortSettle)
	err := rn.start([]byte(`{"outbounds":[{"type":"nonexistent_proto"}]}`))
	if err == nil {
		t.Fatal("want a rejection")
	}
	want := "config rejected by sing-box: FATAL[0000] decode config at /var/lib/aurora/run/config.json: outbounds[0]: unknown outbound type: nonexistent_proto"
	if err.Error() != want {
		t.Fatalf("got %q, want %q", err.Error(), want)
	}
}

// The log file is a diagnostic artifact a human reads in a terminal — it is
// arguably FINE with colour, and stripping happens by reading tailBuffer
// (see tailBuffer.String), not by writing to it, precisely so the separate
// io.MultiWriter sink that feeds the log file never passes through that read
// path at all. This test pins that split: detail is clean, the log file is
// not.
func TestLogFileKeepsColorWhileDetailIsStripped(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) printf '\033[31mFATAL\033[0m boom\n' >&2; exit 1 ;;
esac`), wideSettle)
	err := rn.start([]byte(`{}`))
	if err == nil {
		t.Fatal("want an error")
	}
	if strings.Contains(err.Error(), "\x1b") {
		t.Fatalf("detail must not carry raw escape bytes, got %q", err)
	}
	if !strings.Contains(err.Error(), "FATAL boom") {
		t.Fatalf("detail must still carry the message, got %q", err)
	}
	logBytes, ferr := os.ReadFile(rn.LogPath)
	if ferr != nil {
		t.Fatalf("read log: %v", ferr)
	}
	if !strings.Contains(string(logBytes), "\x1b[31m") {
		t.Fatalf("log file must keep the original colour for a human reading it in a terminal, got %q", logBytes)
	}
}

// ---- argv dispatch: an unrecognised verb must not silently serve
// (Defect 2, reproduced live 2026-08-03: `aurora-svc --help` started the HTTP
// server and began listening on 127.0.0.1:53421) ----------------------------

func TestParseVerbAcceptsBareInvocation(t *testing.T) {
	verb, ok := parseVerb([]string{"aurora-svc"}, "install", "uninstall")
	if !ok || verb != "" {
		t.Fatalf("want (\"\", true) for bare invocation, got (%q, %v)", verb, ok)
	}
}

func TestParseVerbAcceptsRunOnEveryPlatform(t *testing.T) {
	// "run" must be accepted even with no extra verbs at all — it is what
	// systemd's ExecStart (main_linux.go's unitTemplate,
	// app/linux/packaging/aurora-svc.service) and the Windows SCM both pass.
	verb, ok := parseVerb([]string{"aurora-svc", "run"})
	if !ok || verb != "run" {
		t.Fatalf("want (\"run\", true), got (%q, %v)", verb, ok)
	}
}

func TestParseVerbAcceptsPlatformSpecificExtras(t *testing.T) {
	for _, extra := range []string{"install", "uninstall"} {
		verb, ok := parseVerb([]string{"aurora-svc", extra}, "install", "uninstall")
		if !ok || verb != extra {
			t.Fatalf("want (%q, true), got (%q, %v)", extra, verb, ok)
		}
	}
}

// This is the exact defect: `aurora-svc --help` (or any other typo'd verb)
// must not be treated as "serve in the foreground".
func TestParseVerbRejectsAnUnrecognizedVerb(t *testing.T) {
	verb, ok := parseVerb([]string{"aurora-svc", "--help"}, "install", "uninstall")
	if ok {
		t.Fatalf("want ok=false for an unrecognized verb, got verb=%q ok=true", verb)
	}
	if verb != "--help" {
		t.Fatalf("want the rejected verb echoed back for the usage message, got %q", verb)
	}
}

func TestParseVerbRejectsAVerbNotInThisPlatformsExtras(t *testing.T) {
	// "install"/"uninstall" are Windows/Linux concepts; a platform that does
	// not pass them as extras (the macOS dev-only build) must reject them
	// too, not silently fall through to foreground serve.
	if _, ok := parseVerb([]string{"aurora-svc", "install"}); ok {
		t.Fatal("want ok=false when the caller did not list \"install\" as accepted")
	}
}

// ---- small helpers --------------------------------------------------------

func bearer(token string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/start", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	return r
}

func post(t *testing.T, s *server, body, token string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/start", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	s.routes().ServeHTTP(rec, req)
	return rec
}

func jsonString(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return string(b)
}
