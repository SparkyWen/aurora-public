package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"

	"sync/atomic"
	"testing"
	"time"
)

// ---- the root cause: a tunnel that outlives the app that asked for it ------

// fakeOwner is a process handle whose liveness the test controls.
type fakeOwner struct {
	dead     atomic.Bool
	released atomic.Bool
}

func (f *fakeOwner) alive() bool { return !f.dead.Load() }
func (f *fakeOwner) release()    { f.released.Store(true) }

// ownedRunner is testRunner plus an injected owner handle, polled fast enough
// that the tests do not spend real seconds waiting for a heartbeat.
func ownedRunner(t *testing.T, script string) (*Runner, *fakeOwner) {
	t.Helper()
	rn := testRunner(t, fakeSingBox(t, script), shortSettle)
	owner := &fakeOwner{}
	rn.OpenOwner = func(int) (ownerProcess, error) { return owner, nil }
	rn.OwnerPollInterval = 10 * time.Millisecond
	return rn, owner
}

const liveCore = `
case "$1" in
  check) exit 0 ;;
  *) sleep 30 ;;
esac`

// THE regression test for "Aurora still affects networking after I quit the app". Every exit that does not go through the tray's Quit item —
// Task Manager, a crash, a log-off, the installer's own taskkill during an
// upgrade, closing the window on a machine where the tray icon failed to
// install — used to leave sing-box running as SYSTEM with a full-capture TUN
// and no window anywhere to turn it off.
func TestTheTunnelDiesWithTheProcessThatAskedForIt(t *testing.T) {
	rn, owner := ownedRunner(t, liveCore)
	if err := rn.startOwned([]byte(`{"log":{}}`), nil, 4242); err != nil {
		t.Fatal(err)
	}
	if rn.pid() == 0 {
		t.Fatal("want a live child")
	}
	owner.dead.Store(true)
	waitFor(t, time.Second, func() bool { return rn.pid() == 0 })
	if state, _ := rn.state(); state != "stopped" {
		t.Fatalf("want stopped after the owner died, got %q", state)
	}
	// Waited for, not asserted outright: watchOwner releases the handle in a
	// defer that runs AFTER onExit returns, so the tunnel is observably down
	// before the handle is observably closed. Asserting directly here passed
	// in isolation and failed under a full suite run — an ordering the code is
	// entitled to, and a race the test had no business asserting on.
	waitFor(t, time.Second, owner.released.Load)
}

// The headless CLI connects and exits on purpose (see app/lib/cli/cli_app.dart:
// its tunnel is meant to outlive it). Sending no pid must therefore keep the
// pre-ownership behaviour exactly.
func TestNoOwnerPidLeavesTheTunnelRunning(t *testing.T) {
	rn, owner := ownedRunner(t, liveCore)
	if err := rn.startOwned([]byte(`{"log":{}}`), nil, 0); err != nil {
		t.Fatal(err)
	}
	defer rn.stop()
	owner.dead.Store(true) // nobody is watching it
	time.Sleep(80 * time.Millisecond)
	if rn.pid() == 0 {
		t.Fatal("an unowned tunnel must not be torn down")
	}
}

// A watcher whose tunnel has already been replaced must not stop the new one.
// Without the generation guard this is a real sequence: the owner dies while a
// second client's /start holds mu, the watcher wakes up after that start
// finished, and kills a tunnel it never owned.
func TestADeadOwnerDoesNotStopTheNextClientsTunnel(t *testing.T) {
	rn, first := ownedRunner(t, liveCore)
	if err := rn.startOwned([]byte(`{"log":{}}`), nil, 4242); err != nil {
		t.Fatal(err)
	}
	second := &fakeOwner{}
	rn.OpenOwner = func(int) (ownerProcess, error) { return second, nil }
	// A different config forces a genuine restart, i.e. a new generation.
	if err := rn.startOwned([]byte(`{"log":{"level":"info"}}`), nil, 5252); err != nil {
		t.Fatal(err)
	}
	defer rn.stop()
	first.dead.Store(true)
	time.Sleep(80 * time.Millisecond)
	if rn.pid() == 0 {
		t.Fatal("the first owner's death must not touch the second's tunnel")
	}
}

// The app restarting adopts a tunnel it did not start. Ownership has to move
// with it, or the adopted tunnel keeps pointing at a pid that no longer exists.
func TestStatusReclaimsOwnershipOfAnAdoptedTunnel(t *testing.T) {
	rn, first := ownedRunner(t, liveCore)
	if err := rn.startOwned([]byte(`{"log":{}}`), nil, 4242); err != nil {
		t.Fatal(err)
	}
	defer rn.stop()
	second := &fakeOwner{}
	rn.OpenOwner = func(int) (ownerProcess, error) { return second, nil }

	s := &server{guard: staticGuard("tok"), runner: rn}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status?owner_pid=5252", nil)
	req.Header.Set("Authorization", "Bearer tok")
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	if got := rn.ownerPID.Load(); got != 5252 {
		t.Fatalf("want ownership moved to 5252, got %d", got)
	}
	// The old handle is released and its death is now irrelevant.
	first.dead.Store(true)
	time.Sleep(80 * time.Millisecond)
	if rn.pid() == 0 {
		t.Fatal("the replaced owner's death must not stop the tunnel")
	}
}

// A re-issued connect for the identical config takes the idempotent early
// return. Ownership still has to transfer, or an app that reconnected after a
// restart would be watched through its predecessor's handle.
func TestAnIdenticalRestartStillTransfersOwnership(t *testing.T) {
	rn, _ := ownedRunner(t, liveCore)
	if err := rn.startOwned([]byte(`{"log":{}}`), nil, 4242); err != nil {
		t.Fatal(err)
	}
	defer rn.stop()
	if err := rn.startOwned([]byte(`{"log":{}}`), nil, 5252); err != nil {
		t.Fatal(err)
	}
	if got := rn.ownerPID.Load(); got != 5252 {
		t.Fatalf("want ownership moved to 5252, got %d", got)
	}
}

// ...but the idempotent path only ever UPGRADES ownership. `aurora-cli connect`
// run against an already-running GUI session sends the identical config and no
// pid; if that un-owned the tunnel, quitting the app would stop cleaning up
// again — i.e. the whole bug back, introduced by the CLI's fire-and-forget
// contract rather than by anything the user did wrong.
func TestAnUnownedRestartDoesNotDisownALiveTunnel(t *testing.T) {
	rn, owner := ownedRunner(t, liveCore)
	if err := rn.startOwned([]byte(`{"log":{}}`), nil, 4242); err != nil {
		t.Fatal(err)
	}
	if err := rn.startOwned([]byte(`{"log":{}}`), nil, 0); err != nil {
		t.Fatal(err)
	}
	if got := rn.ownerPID.Load(); got != 4242 {
		t.Fatalf("want the GUI still owning it, got %d", got)
	}
	// And the owner's death still works.
	owner.dead.Store(true)
	waitFor(t, time.Second, func() bool { return rn.pid() == 0 })
}

// /status must keep answering instantly even while a launch holds mu — the
// claim path is allowed to skip, never to queue. Regression guard for the
// TryLock in claimOwner.
func TestStatusWithAnOwnerPidStillAnswersDuringASlowStart(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, slowCore), 0)
	rn.ClashPing = func(int, string) bool { return false }
	rn.ReadyTimeout = 3 * time.Second
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"})
	}()
	defer func() { rn.stop(); <-done }()
	time.Sleep(200 * time.Millisecond)

	s := &server{guard: staticGuard("tok"), runner: rn}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/status?owner_pid=4242", nil)
	req.Header.Set("Authorization", "Bearer tok")
	answered := make(chan struct{})
	go func() { s.routes().ServeHTTP(rec, req); close(answered) }()
	select {
	case <-answered:
	case <-time.After(time.Second):
		t.Fatal("/status queued behind a launch")
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
}

// An owner_pid on the wire has to reach the runner; the field name is a
// cross-language contract with app/lib/core/aurora_svc_client.dart.
func TestHandleStartParsesOwnerPidFromJSON(t *testing.T) {
	rn, owner := ownedRunner(t, liveCore)
	s := &server{guard: staticGuard("tok"), runner: rn}
	body := fmt.Sprintf(
		`{"config":%s,"owner_pid":4242}`, jsonString(`{"log":{}}`),
	)
	if rec := post(t, s, body, "tok"); rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", rec.Code, rec.Body)
	}
	if got := rn.ownerPID.Load(); got != 4242 {
		t.Fatalf("want owner 4242, got %d", got)
	}
	owner.dead.Store(true)
	waitFor(t, time.Second, func() bool { return rn.pid() == 0 })
}

// An app build that predates ownership must keep working untouched.
func TestHandleStartWithoutOwnerPidClaimsNobody(t *testing.T) {
	rn, _ := ownedRunner(t, liveCore)
	defer rn.stop()
	s := &server{guard: staticGuard("tok"), runner: rn}
	body := fmt.Sprintf(`{"config":%s}`, jsonString(`{"log":{}}`))
	if rec := post(t, s, body, "tok"); rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", rec.Code, rec.Body)
	}
	if got := rn.ownerPID.Load(); got != 0 {
		t.Fatalf("want no owner, got %d", got)
	}
}

// ---- graceful stop --------------------------------------------------------

// sing-box removes the TUN device, its routes and its firewall state from the
// handler it runs on SIGTERM/CTRL_BREAK. A stop that goes straight to
// TerminateProcess runs none of that, which is where orphaned adapters and a
// resolver still full of tunnel-era answers come from.
func TestStopAsksTheCoreToLeaveBeforeKillingIt(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "graceful")
	sb := fakeSingBox(t, fmt.Sprintf(`
case "$1" in
  check) exit 0 ;;
  *)
    trap 'echo yes > %s; exit 0' TERM
    sleep 30 >/dev/null 2>&1 &
    wait
    ;;
esac`, marker))
	rn := testRunner(t, sb, wideSettle)
	if err := rn.start([]byte(`{"log":{}}`)); err != nil {
		t.Fatal(err)
	}
	rn.stop()
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("the core was killed without being asked to leave: %v", err)
	}
}

// A core that ignores the ask still has to die, and within a bounded time.
func TestStopKillsACoreThatIgnoresTheAsk(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *)
    trap '' TERM
    sleep 30 >/dev/null 2>&1 &
    wait
    ;;
esac`)
	rn := testRunner(t, sb, wideSettle)
	if err := rn.start([]byte(`{"log":{}}`)); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	rn.stop()
	if rn.pid() != 0 {
		t.Fatal("want the child gone")
	}
	if elapsed := time.Since(started); elapsed > gracefulStopBudget+8*time.Second {
		t.Fatalf("stop took %s, past its own budget", elapsed)
	}
}

// ---- the wall of red ------------------------------------------------------

func TestLastLinesKeepsTheEndAndMarksTheCut(t *testing.T) {
	for _, tc := range []struct{ name, in, want string }{
		{"empty", "", ""},
		{"one line", "only", "only"},
		{"exactly n", "a\nb", "a\nb"},
		{"clipped", "a\nb\nc\nd\ne", "…\nd\ne"},
		{"blank lines are not content", "a\n\n\nb\n\nc", "…\nb\nc"},
		{"carriage returns", "a\r\nb\r\nc\r\n", "…\nb\nc"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := lastLines(tc.in, errorTailLines); got != tc.want {
				t.Fatalf("lastLines(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// The reported symptom was a long red wall of five or six error lines. The cause belongs in the
// dialog; the startup chatter above it belongs in the log file.
func TestAStartFailureQuotesTheLastWordsNotTheWholeLog(t *testing.T) {
	sb := fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *)
    echo "line one"
    echo "line two"
    echo "line three"
    echo "FATAL the actual cause" >&2
    exit 1 ;;
esac`)
	rn := testRunner(t, sb, wideSettle)
	err := rn.start([]byte(`{"log":{}}`))
	if err == nil {
		t.Fatal("want a failure")
	}
	if !strings.Contains(err.Error(), "FATAL the actual cause") {
		t.Fatalf("the cause must survive clipping, got %q", err)
	}
	if strings.Contains(err.Error(), "line one") {
		t.Fatalf("startup chatter must be clipped, got %q", err)
	}
	// The full text stays where a human can go and read it.
	if !strings.Contains(rn.tailString(), "line one") {
		t.Fatal("the whole tail must survive for /diagnose and the log")
	}
}

// ---- /diagnose ------------------------------------------------------------

// "It says connected and nothing works" (2026-08-14, a machine nobody could
// reach) needs the machine's own view of its interfaces, not another repetition
// that sing-box is running.
func TestDiagnoseReportsTheMachinesInterfaces(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, liveCore), shortSettle)
	s := &server{guard: staticGuard("tok"), runner: rn}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/diagnose", nil)
	req.Header.Set("Authorization", "Bearer tok")
	s.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	var got diagnosis
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("bad json: %v", err)
	}
	if got.TunInterface != auroraTunInterfaceName {
		t.Fatalf("want the tun name reported, got %q", got.TunInterface)
	}
	if len(got.Interfaces) == 0 {
		t.Fatal("want the interface table; every machine has at least loopback")
	}
	if got.State != "stopped" {
		t.Fatalf("want stopped, got %q", got.State)
	}
}

func TestDiagnoseNeedsTheToken(t *testing.T) {
	s := &server{guard: staticGuard("tok"), runner: &Runner{}}
	rec := httptest.NewRecorder()
	s.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/diagnose", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

// ---- uninstall ------------------------------------------------------------

// The shared token and the last-run config (real credentials, in plain text)
// must not survive an uninstall.
func TestPurgeMachineStateRemovesTheStateDirectory(t *testing.T) {
	base := filepath.Join(t.TempDir(), "Aurora")
	paths := Paths{StateDir: base}
	if err := os.MkdirAll(filepath.Join(base, "run"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"svc-token", filepath.Join("run", "config.json")} {
		if err := os.WriteFile(filepath.Join(base, name), []byte("secret"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	purgeMachineState(paths)
	if _, err := os.Stat(base); !os.IsNotExist(err) {
		t.Fatalf("want %s gone, stat err = %v", base, err)
	}
}

// ---- helpers --------------------------------------------------------------

func waitFor(t *testing.T, budget time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(budget)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("condition not met within %s", budget)
}
