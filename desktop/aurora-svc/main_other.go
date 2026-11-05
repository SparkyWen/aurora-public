//go:build !windows && !linux

// Neither-Windows-nor-Linux entrypoint (macOS today): runs the same HTTP
// server in the foreground. Windows integrates with the SCM and Linux with
// systemd; this variant exists so the package compiles and its logic can be
// exercised on macOS.
//
// This file used to ignore os.Args entirely and always serve — the same hole
// as Defect 2 (reproduced live 2026-08-03 on Linux: `aurora-svc --help`
// silently started listening on 127.0.0.1:53421), just with no argument
// check at all rather than an incomplete one. It gets the same fix via the
// shared parseVerb/printUsage in main.go.
package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
)

// runMain is main()'s logic with exit/serve injected as parameters, purely so
// TestRunMainRejectsUnknownVerbWithoutServing (main_other_test.go) can prove
// an unrecognized verb never reaches the code that binds svcListenAddr,
// without actually terminating the test process or binding the real port.
// main() below wires this to the real os.Exit and listenLocal/http.Serve.
func runMain(args []string, exit func(int), serve func()) {
	verb, ok := parseVerb(args)
	if !ok {
		fmt.Fprintf(os.Stderr, "%s: unrecognized argument %q\n", filepath.Base(args[0]), verb)
		printUsage(filepath.Base(args[0]))
		exit(2)
		return
	}
	_ = verb // only "run" and bare invocation are accepted on this platform
	serve()
}

func main() {
	runMain(os.Args, os.Exit, func() {
		ln, err := listenLocal(svcListenAddr)
		if err != nil {
			os.Exit(1)
		}
		_ = http.Serve(ln, newServer().routes())
	})
}
