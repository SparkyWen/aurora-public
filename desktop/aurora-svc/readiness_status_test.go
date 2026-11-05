package main

import (
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestStatusPublishesSessionOnlyAfterReadiness(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, slowCore), 0)
	var ready atomic.Bool
	rn.ClashPing = func(int, string) bool { return ready.Load() }
	done := startInFlight(t, rn)
	defer func() { rn.stop(); <-done }()
	s := &server{guard: staticGuard("tok"), runner: rn}
	if state, probe := statusSession(t, s); state != "starting" || probe != nil {
		t.Fatalf("unready core advertised a session: state=%s, probe present=%v", state, probe != nil)
	}
	ready.Store(true)
	deadline := time.Now().Add(2 * time.Second)
	for {
		state, probe := statusSession(t, s)
		if state == "running" {
			if probe == nil || probe.Port != 1 || probe.Secret != "x" {
				t.Fatal("ready core did not publish its current session")
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("readiness did not publish running: state=%s", state)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestStatusReportsStartingDuringPreflight(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, slowCore), 0)
	entered, release := make(chan struct{}), make(chan struct{})
	var unblock sync.Once
	rn.TunnelExists = func(string) bool { close(entered); <-release; return false }
	rn.ClashPing = func(int, string) bool { return true }
	done := make(chan error, 1)
	go func() { done <- rn.startWithProbe([]byte(`{"log":{}}`), &clashProbe{Port: 1, Secret: "x"}) }()
	defer func() { unblock.Do(func() { close(release) }); rn.stop(); <-done }()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("start never entered preflight")
	}
	s := &server{guard: staticGuard("tok"), runner: rn}
	if state, probe := statusSession(t, s); state != "starting" || probe != nil {
		t.Fatalf("preflight reported state=%s, probe present=%v", state, probe != nil)
	}
}

func TestLegacyStartPublishesRunningOnlyAfterSettle(t *testing.T) {
	rn := testRunner(t, fakeSingBox(t, slowCore), time.Second)
	done := make(chan error, 1)
	go func() { done <- rn.start([]byte(`{"log":{}}`)) }()
	defer func() { rn.stop(); <-done }()
	deadline := time.Now().Add(2 * time.Second)
	for !strings.Contains(rn.tailString(), "RUNNING") {
		if time.Now().After(deadline) {
			t.Fatal("core never launched")
		}
		time.Sleep(10 * time.Millisecond)
	}
	s := &server{guard: staticGuard("tok"), runner: rn}
	if state, probe := statusSession(t, s); state != "starting" || probe != nil {
		t.Fatalf("legacy settle advertised state=%s, probe present=%v", state, probe != nil)
	}
	for {
		if state, probe := statusSession(t, s); state == "running" {
			if probe != nil {
				t.Fatal("legacy start invented session credentials")
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("settled legacy core never became running")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
