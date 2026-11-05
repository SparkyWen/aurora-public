package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// defaultCheckTimeout bounds `sing-box check`. It parses a 4 KB config; a second
// is already generous, and a hung check must not hold the connect flow.
const defaultCheckTimeout = 5 * time.Second

// staleAdapterGrace is the last chance a leftover adapter gets to disappear on
// its own before we start over it. stopLocked may already have spent
// tunnelTeardownBudget waiting. Expiry does not prove that Windows has finished
// removing the old device; readiness must still catch a failed replacement.
const staleAdapterGrace = 2 * time.Second

// preflight answers "will this even start?" BEFORE we hand the config to a
// SYSTEM/root-level sing-box.
//
// Without it, every startup failure looked identical from the app: /start
// returned 200 (the child had not died inside the settle window yet) and the
// user got "the request was accepted but the core did not come up" with no cause attached. Each check
// below turns one whole class of that into a quotable sentence.
func (rn *Runner) preflight(config []byte) error {
	// A leftover adapter is waited out, then started over — NOT refused.
	//
	// This used to be a hard refusal, and that refusal is the 500 the user hit
	// ("sometimes 500, reconnecting fixes it"). The reasoning behind it was
	// that racing sing-box against a device it would lose produces an opaque
	// "core did not come up", so naming the collision first was better. What it
	// missed is that sing-tun attempts CreateAdapter and falls back to
	// OpenAdapter on ErrExist (sing-tun tun_windows.go, New). Refusing every
	// attempt prevented that recovery path from running at all. However,
	// Wintun 0.14.1 queues orphan cleanup asynchronously on API exit; it does
	// not guarantee a synchronous sweep before CreateAdapter. Device tests
	// have reproduced a first creation failure followed by a successful retry
	// after these budgets expire. Proceeding preserves recovery, but must not
	// be treated as proof that the leftover device was safely removed.
	//
	// startWithProbe's identical-config early return means we are never here
	// while our OWN child still owns the adapter, so a hit is always a previous
	// untracked instance: a teardown that outlived tunnelTeardownBudget, or a
	// service restart that lost track of a child. Give a slow teardown a last
	// grace period, then proceed and let sing-box deal with what is left. The
	// fact is remembered (staleAdapter) so a failure that follows can say the
	// start began from a dirty slate.
	if rn.tunnelExists()(auroraTunInterfaceName) {
		rn.tunnelGone()(auroraTunInterfaceName, staleAdapterGrace)
		rn.staleAdapter = rn.tunnelExists()(auroraTunInterfaceName)
	}
	if _, err := os.Stat(rn.SingBoxPath); err != nil {
		return fmt.Errorf("sing-box binary missing at %s", rn.SingBoxPath)
	}
	for _, required := range rn.RequiredFiles {
		if _, err := os.Stat(required); err != nil {
			return fmt.Errorf("required file missing: %s", filepath.Base(required))
		}
	}
	if err := writeRunConfig(rn.ConfigPath, config); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	timeout := rn.CheckTimeout
	if timeout <= 0 {
		timeout = defaultCheckTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(
		ctx, rn.SingBoxPath, "check", "-c", rn.ConfigPath,
	).CombinedOutput()
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		// A check that never returns says nothing about the config; refusing to
		// start over it would be worse than trying.
		return nil
	}
	// `sing-box check`'s CombinedOutput() is a second, independent capture
	// site from tailBuffer (this is a synchronous one-shot exec, not the
	// long-running child's streamed stdout/stderr) — it needs the exact same
	// treatment. This is in fact the path the Defect-1 repro came through:
	// "config rejected by sing-box: <colourised FATAL line>" is built right
	// here. See ansi.go for why stripping lives at the two capture sites
	// rather than the log file too.
	detail := strings.TrimSpace(string(stripANSI(out)))
	if detail == "" {
		detail = err.Error()
	}
	return fmt.Errorf("config rejected by sing-box: %s", detail)
}
