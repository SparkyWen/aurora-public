//go:build windows

package main

import (
	"testing"
	"time"

	"golang.org/x/sys/windows/svc"
)

// Invoke the production Execute method, without registering or stopping an SCM
// service. No child is installed or started. Holding the real Runner mutex
// models owner cleanup that has reaped the child but is still releasing the TUN.
func TestWindowsServiceStopReportsPendingBeforeCleanup(t *testing.T) {
	for _, tc := range []struct {
		name string
		cmd  svc.Cmd
	}{
		{"stop", svc.Stop},
		{"shutdown", svc.Shutdown},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("ProgramData", t.TempDir())
			rn := &Runner{}
			rn.mu.Lock()
			locked := true
			// An empty guard rejects every HTTP request. If an installed service
			// already owns the listener, Execute fails; never stop it for this test.
			a := &auroraService{srv: &server{runner: rn, guard: &Guard{}}}
			requests := make(chan svc.ChangeRequest, 1)
			states := make(chan svc.Status, 8)
			type result struct {
				specific bool
				code     uint32
			}
			done := make(chan result, 1)
			go func() {
				specific, code := a.Execute(nil, requests, states)
				done <- result{specific, code}
			}()
			finished := false
			t.Cleanup(func() {
				if locked {
					rn.mu.Unlock()
				}
				select {
				case requests <- svc.ChangeRequest{Cmd: svc.Stop}:
				default:
				}
				close(requests)
				if !finished {
					select {
					case <-done:
					case <-time.After(5 * time.Second):
						t.Error("Execute did not finish after releasing cleanup")
					}
				}
			})
			nextState := func() svc.Status {
				t.Helper()
				select {
				case state := <-states:
					return state
				case result := <-done:
					finished = true
					t.Fatalf("Execute exited before reporting state: %+v (listener may be occupied)", result)
				case <-time.After(3 * time.Second):
					t.Fatal("Execute did not report state while cleanup remained blocked")
				}
				return svc.Status{}
			}
			if state := nextState(); state.State != svc.StartPending {
				t.Fatalf("initial state = %v", state.State)
			}
			if state := nextState(); state.State != svc.Running {
				t.Fatalf("ready state = %v", state.State)
			}
			requests <- svc.ChangeRequest{Cmd: tc.cmd}
			if state := nextState(); state.State != svc.StopPending || state.Accepts != 0 {
				t.Fatalf("state during cleanup = %+v; want StopPending accepting no controls", state)
			}
			select {
			case <-done:
				finished = true
				t.Fatal("Execute returned without waiting for cleanup")
			default:
			}
			rn.mu.Unlock()
			locked = false
			select {
			case result := <-done:
				finished = true
				if result.specific || result.code != 0 {
					t.Fatalf("clean stop result = %+v", result)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("Execute did not finish after cleanup")
			}
		})
	}
}
