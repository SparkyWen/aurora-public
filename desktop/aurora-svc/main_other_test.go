//go:build !windows && !linux

package main

import "testing"

// runMain's exit/serve are injected exactly so this test can prove the thing
// Defect 2 was actually about: an unrecognized verb must never reach the code
// path that binds 127.0.0.1:53421, not just that it "prints something". This
// is the only platform variant whose main() logic actually executes when
// `go test` runs on macOS, since main_linux.go and service_windows.go are
// excluded from a darwin build by their own build tags — the Linux/Windows
// fixes are covered by TestParseVerb* (main_test.go, no build tag) plus the
// cross-compile checks (`go build`), not by running their main() here.
func TestRunMainRejectsUnknownVerbWithoutServing(t *testing.T) {
	served := false
	exitCode := 0
	exited := false
	runMain([]string{"aurora-svc", "--help"}, func(code int) { exited = true; exitCode = code }, func() { served = true })
	if served {
		t.Fatal("an unrecognized verb must not start the server")
	}
	if !exited || exitCode == 0 {
		t.Fatalf("want a non-zero exit for an unrecognized verb, got exited=%v code=%d", exited, exitCode)
	}
}

func TestRunMainServesForBareInvocationAndRun(t *testing.T) {
	for _, args := range [][]string{{"aurora-svc"}, {"aurora-svc", "run"}} {
		served := false
		runMain(args, func(code int) { t.Fatalf("must not exit(%d) for args %v", code, args) }, func() { served = true })
		if !served {
			t.Fatalf("want serve() to run for args %v", args)
		}
	}
}
