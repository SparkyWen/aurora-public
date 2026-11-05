package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type delayedStartBody struct {
	reader  *io.PipeReader
	started chan struct{}
	seen    bool
}

func (r *delayedStartBody) Read(p []byte) (int, error) {
	if !r.seen {
		r.seen = true
		close(r.started)
	}
	return r.reader.Read(p)
}
func (r *delayedStartBody) Close() error { return r.reader.Close() }

func TestStopCancelsAStartWhoseBodyIsStillArriving(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) exec sleep 30 ;;
esac`), 0)
	defer rn.stop()
	s := &server{guard: staticGuard("tok"), runner: rn}
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	started := make(chan struct{})
	req := httptest.NewRequest(http.MethodPost, "/start", &delayedStartBody{reader: reader, started: started})
	req.Header.Set("Authorization", "Bearer tok")
	response := httptest.NewRecorder()
	finished := make(chan struct{})
	go func() { s.handleStart(response, req); close(finished) }()
	<-started
	stopRequest := httptest.NewRequest(http.MethodPost, "/stop", nil)
	stopRequest.Header.Set("Authorization", "Bearer tok")
	stopResponse := httptest.NewRecorder()
	s.handleStop(stopResponse, stopRequest)
	if stopResponse.Code != http.StatusOK {
		t.Fatal("stop was not accepted")
	}
	if _, err := writer.Write([]byte(`{"config":"{\"log\":{}}"}`)); err != nil {
		t.Fatal(err)
	}
	writer.Close()
	<-finished
	if state, _ := rn.state(); state != "stopped" {
		t.Fatalf("late /start ran after acknowledged /stop: state=%s, start status=%d", state, response.Code)
	}
}

func TestCancelledStartRequestCannotLaunch(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) exec sleep 30 ;;
esac`), 0)
	defer rn.stop()
	s := &server{guard: staticGuard("tok"), runner: rn}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := httptest.NewRequest(http.MethodPost, "/start", strings.NewReader(`{"config":"{\"log\":{}}"}`)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer tok")
	response := httptest.NewRecorder()
	s.handleStart(response, req)
	if response.Code == http.StatusOK || rn.pid() != 0 {
		t.Fatal("a cancelled HTTP request launched a core")
	}
	if state, _ := rn.state(); state != "stopped" {
		t.Fatalf("a cancelled request changed the current runner state to %s", state)
	}
}

func TestStartCancelledDuringReadinessReapsItsChild(t *testing.T) {
	for _, tc := range []struct{ name, probeBody string }{
		{"legacy_settle", ""},
		{"readiness", `,"clash_probe":{"port":1,"secret":"test"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rn := testRunner(t, fakeSingBox(t, slowCore), 0)
			rn.ReadyTimeout = 30 * time.Second
			rn.SettleDelay = 30 * time.Second
			rn.ClashPing = func(int, string) bool { return false }
			s := &server{guard: staticGuard("tok"), runner: rn}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			req := httptest.NewRequest(http.MethodPost, "/start", strings.NewReader(
				`{"config":"{\"log\":{}}"`+tc.probeBody+`}`,
			)).WithContext(ctx)
			req.Header.Set("Authorization", "Bearer tok")
			response := httptest.NewRecorder()
			done := make(chan struct{})
			go func() { s.handleStart(response, req); close(done) }()
			defer func() { rn.stop(); <-done }()
			deadline := time.Now().Add(10 * time.Second)
			for !strings.Contains(rn.tailString(), "RUNNING") {
				if time.Now().After(deadline) {
					t.Fatal("child did not start")
				}
				time.Sleep(20 * time.Millisecond)
			}
			cancel()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("cancelled HTTP start kept its child and readiness wait alive")
			}
			if response.Code == http.StatusOK || rn.pid() != 0 {
				t.Fatal("cancelled HTTP start succeeded or left its child running")
			}
			if !strings.Contains(response.Body.String(), "start_cancelled") {
				t.Fatal("cancelled HTTP start did not identify cancellation")
			}
		})
	}
}

func TestStartCancelledDuringPreflightNeverLaunches(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "launched")
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) touch `+marker+`; exec sleep 30 ;;
esac`), shortSettle)
	defer rn.stop()
	entered, resume := make(chan struct{}), make(chan struct{})
	rn.TunnelExists = func(string) bool { close(entered); <-resume; return false }
	s := &server{guard: staticGuard("tok"), runner: rn}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodPost, "/start", strings.NewReader(`{"config":"{\"log\":{}}"}`)).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer tok")
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { s.handleStart(response, req); close(done) }()
	<-entered
	cancel()
	close(resume)
	<-done
	if response.Code == http.StatusOK {
		t.Fatal("request cancelled during preflight succeeded")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("request cancelled during preflight launched a core")
	}
}

func TestUnexpectedCoreExitWaitsForTunnelTeardown(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, slowCore), shortSettle)
	defer rn.stop()
	var cleanups atomic.Int32
	rn.TunnelGone = func(name string, _ time.Duration) {
		if name != auroraTunInterfaceName {
			t.Errorf("cleanup waited for unrelated interface %q", name)
		}
		cleanups.Add(1)
	}
	if err := rn.start([]byte(`{"log":{}}`)); err != nil {
		t.Fatal(err)
	}
	child, err := os.FindProcess(rn.pid())
	if err != nil {
		t.Fatal(err)
	}
	if err := child.Kill(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, 2*time.Second, func() bool { state, _ := rn.state(); return state == "error" })
	if rn.pid() != 0 {
		t.Fatal("exited child remained registered")
	}
	if cleanups.Load() != 1 {
		t.Fatal("unexpected core exit skipped tunnel teardown cleanup")
	}
}

func TestLegacySettleCannotCommitAnAlreadyCancelledRequest(t *testing.T) {
	// Exercise modern synchronous timers even while go.mod retains 1.22's
	// compatibility defaults, so the elapsed timer is ready at select time.
	t.Setenv("GODEBUG", "asynctimerchan=0")
	rn := testRunner(t, fakeSingBox(t, slowCore), time.Nanosecond)
	defer rn.stop()
	s := &server{guard: staticGuard("tok"), runner: rn}
	// Both the elapsed settle timer and request cancellation are selectable.
	// Exercise repeated real launches so the timer branch cannot escape its
	// final cancellation check just because select chose it first.
	for attempt := 0; attempt < 32; attempt++ {
		ctx, cancel := context.WithCancel(context.Background())
		rn.OpenOwner = func(int) (ownerProcess, error) {
			cancel() // after preflight/spawn, immediately before the settle wait
			return &fakeOwner{}, nil
		}
		req := httptest.NewRequest(http.MethodPost, "/start", strings.NewReader(
			`{"config":"{\"log\":{}}","owner_pid":4242}`,
		)).WithContext(ctx)
		req.Header.Set("Authorization", "Bearer tok")
		response := httptest.NewRecorder()
		s.handleStart(response, req)
		cancel()
		if response.Code == http.StatusOK || rn.pid() != 0 {
			t.Fatalf("elapsed settle timer committed cancelled launch %d", attempt)
		}
	}
}
