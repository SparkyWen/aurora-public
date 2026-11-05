//go:build windows

package main

import (
	"os/exec"
	"sync"
	"syscall"

	"golang.org/x/sys/windows"
)

// Graceful stop on Windows, and why it takes a console to get one.
//
// sing-box does its entire teardown in the handler it installs with
// signal.Notify(os.Interrupt, SIGTERM, SIGHUP) — closing the TUN, which is what
// removes the wintun adapter, drops the WFP filters and flushes the resolver
// cache. TerminateProcess (what os.Process.Kill does here) runs none of it, so
// every stop this service performed left the machine to clean up after us
// asynchronously, and sometimes not at all: a half-created adapter outlives the
// process that made it, and the next start collides with exactly that wreckage
// because sing-tun derives the adapter GUID from the interface name.
//
// Windows has no kill(2). The only way to ask a console program to stop is a
// console control event, and GenerateConsoleCtrlEvent can only reach processes
// attached to the CALLER's console — a service has none. So we allocate one.
// It is never shown (a service runs in session 0 with no interactive desktop);
// it exists purely as the rendezvous that makes the event deliverable. The
// child then has to be spawned into its own process group, or the event has no
// group id to address that isn't also ours.
//
// Every step is best-effort and the caller falls straight back to Kill if any
// of it fails (see Runner.stopLocked). An older Windows, a locked-down session
// 0, a machine that refuses AllocConsole — all end in exactly the behaviour
// this service had before, never in a stop that does not happen.
var (
	kernel32             = windows.NewLazySystemDLL("kernel32.dll")
	procAllocConsole     = kernel32.NewProc("AllocConsole")
	procGetConsoleWindow = kernel32.NewProc("GetConsoleWindow")
	consoleOnce          sync.Once
	consoleReady         bool
)

// hasConsole reports whether this process is already attached to one.
// GetConsoleWindow returns NULL when it is not — that is the documented probe,
// and it stays correct for a service whose console is not visible.
func hasConsole() bool {
	if procGetConsoleWindow.Find() != nil {
		return false
	}
	handle, _, _ := procGetConsoleWindow.Call()
	return handle != 0
}

// ensureConsole attaches a console exactly once per process lifetime.
//
// Once, and cached: prepareChild (before spawn) and signalGracefulStop (at
// teardown) must agree. If the console could not be had, prepareChild does not
// put the child in its own process group, and signalGracefulStop must therefore
// not try to address one — a control event aimed at a pid that is not a group
// leader is refused, but relying on that refusal instead of on the two callers
// giving the same answer would be building on an accident.
func ensureConsole() bool {
	consoleOnce.Do(func() {
		if hasConsole() {
			consoleReady = true
			return
		}
		if procAllocConsole.Find() != nil {
			return
		}
		ok, _, _ := procAllocConsole.Call()
		consoleReady = ok != 0
	})
	return consoleReady
}

// prepareChild runs BEFORE cmd.Start(): CreationFlags is read by the kernel at
// spawn, so it cannot be applied afterwards the way the job-object supervision
// in superviseChild is.
//
// CREATE_NEW_PROCESS_GROUP makes the child its own group leader, which is the
// only thing GenerateConsoleCtrlEvent can address. Its documented side effect —
// the child ignores CTRL_C — does not matter to us: nobody sends CTRL_C to a
// service's child, and CTRL_BREAK is delivered regardless.
func prepareChild(cmd *exec.Cmd) {
	if !ensureConsole() {
		return
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.CreationFlags |= windows.CREATE_NEW_PROCESS_GROUP
}

// signalGracefulStop asks sing-box to shut itself down. Returns whether the ask
// was delivered — not whether it was obeyed; the caller bounds the wait and
// kills on expiry.
//
// Go's runtime maps CTRL_BREAK_EVENT onto SIGINT, which reaches os.Interrupt,
// which is what sing-box's cmd_run.go is listening for.
func signalGracefulStop(cmd *exec.Cmd) bool {
	if cmd == nil || cmd.Process == nil {
		return false
	}
	if !ensureConsole() {
		return false
	}
	return windows.GenerateConsoleCtrlEvent(
		windows.CTRL_BREAK_EVENT,
		uint32(cmd.Process.Pid),
	) == nil
}
