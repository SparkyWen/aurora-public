package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func sessionRequest(s *server, path, token string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	s.routes().ServeHTTP(rec, req)
	return rec
}

func statusSession(t *testing.T, s *server) (string, *clashProbe) {
	t.Helper()
	rec := sessionRequest(s, "/status", "tok")
	var body struct {
		State string      `json:"state"`
		Probe *clashProbe `json:"clash_probe"`
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status code = %d", rec.Code)
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return body.State, body.Probe
}

func TestStatusSessionFollowsCurrentChildAndIsPrivate(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) exec sleep 30 ;;
esac`), 0)
	rn.ClashPing = func(int, string) bool { return true }
	s := &server{guard: staticGuard("tok"), runner: rn}
	defer rn.stop()
	for i, session := range []struct {
		config, secret string
		port           int
	}{
		{`{"log":{}}`, "first-session-secret", 41234},
		{`{"log":{"level":"info"}}`, "second-session-secret", 42345},
	} {
		body, _ := json.Marshal(map[string]any{
			"config":      session.config,
			"clash_probe": map[string]any{"port": session.port, "secret": session.secret},
		})
		if rec := post(t, s, string(body), "tok"); rec.Code != http.StatusOK {
			t.Fatalf("start %d: %d", i, rec.Code)
		}
		state, probe := statusSession(t, s)
		if state != "running" || probe == nil || probe.Port != session.port || probe.Secret != session.secret {
			t.Fatalf("status did not publish the current session coordinates (state=%s)", state)
		}
		unauthorized := sessionRequest(s, "/status", "wrong-token")
		if unauthorized.Code != http.StatusUnauthorized || strings.Contains(unauthorized.Body.String(), session.secret) {
			t.Fatal("unauthorized status exposed session credentials")
		}
		diagnostic := sessionRequest(s, "/diagnose", "tok")
		if strings.Contains(diagnostic.Body.String(), session.secret) || strings.Contains(diagnostic.Body.String(), "clash_probe") {
			t.Fatal("shareable diagnosis exposed session credentials")
		}
	}
	// Clear credentials before waiting for slow OS adapter teardown.
	rn.TunnelGone = func(string, time.Duration) {
		if _, probe := statusSession(t, s); probe != nil {
			t.Error("session credentials survived into tunnel teardown")
		}
	}
	rn.stop()
	state, probe := statusSession(t, s)
	if state != "stopped" || probe != nil {
		t.Fatal("stopped runner retained a session")
	}
}

func TestStatusSessionDoesNotWaitForReadiness(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) echo RUNNING; exec sleep 30 ;;
esac`), 0)
	rn.ReadyTimeout = 30 * time.Second
	rn.ClashPing = func(int, string) bool { return false }
	done := startInFlight(t, rn)
	defer func() { rn.stop(); <-done }()
	s := &server{guard: staticGuard("tok"), runner: rn}
	before := time.Now()
	state, probe := statusSession(t, s)
	if time.Since(before) > time.Second {
		t.Fatal("session lookup waited behind the readiness lock")
	}
	if state != "starting" || probe != nil {
		t.Fatalf("unready child must not advertise an adoptable session: state=%s, probe present=%v", state, probe != nil)
	}
}

func TestStatusSessionClearsOnFailedStart(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, `
case "$1" in
  check) exit 0 ;;
  *) exec sleep 30 ;;
esac`), 0)
	rn.ReadyTimeout = 50 * time.Millisecond
	rn.ClashPing = func(int, string) bool { return false }
	defer rn.stop()
	if err := rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 41234, Secret: "failed-secret"}); err == nil {
		t.Fatal("expected readiness failure")
	}
	s := &server{guard: staticGuard("tok"), runner: rn}
	state, probe := statusSession(t, s)
	if state != "error" || probe != nil {
		t.Fatal("failed runner retained session credentials")
	}
}
