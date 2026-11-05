package main

import "time"

// The tunnel belongs to whoever asked for it, and must not outlive them.
//
// Root cause this file exists for (user report): "Aurora still affects
// networking after I quit the app". The privileged side runs as LocalSystem/root and lives in
// its own process; the GUI runs as the logged-in user. Nothing connected the
// two lifetimes. Every way of leaving the app that does NOT go through the
// tray's Quit item — closing the window when the tray icon failed to install
// (desktop_shell only intercepts the close when trayManager.setIcon succeeded),
// Task Manager's End task, a crash, a log-off, and the installer's own
// `taskkill /IM aurora.exe /F` during an upgrade — left sing-box running with a
// full-capture TUN owning the machine's routing table, and no window anywhere
// to turn it off.
//
// A heartbeat would have to guess a timeout. Watching the process the caller
// names is exact: the OS tells us, there is no interval to tune, and a client
// that comes back (app restart adopting a live tunnel) re-claims through
// /status. Opt-in by construction — a caller that sends no pid gets no watch,
// which is what `aurora-cli connect` needs, since it deliberately connects and
// exits while the tunnel stays up.

// ownerPollInterval is how often a claimed owner is checked. One second is far
// below any human's perception of "I quit and it's still tunnelling" and costs
// one handle query per second.
const ownerPollInterval = time.Second

// ownerProcess is a live handle on the process that asked for this tunnel.
//
// On Windows this really is a handle, taken at claim time: it pins the PID so a
// recycled process id can never be mistaken for the owner still being alive.
// Elsewhere it is the pid plus a signal-0 probe. See owner_windows.go /
// owner_other.go.
type ownerProcess interface {
	alive() bool
	release()
}

// watchOwner polls owner until it exits or stop is closed, then calls onExit.
//
// onExit is called at most once, and never after stop is closed — the caller
// closes stop from inside the same critical section that forgets the owner, so
// a tunnel that was already torn down for another reason cannot be torn down a
// second time by this goroutine.
func watchOwner(
	owner ownerProcess,
	stop <-chan struct{},
	interval time.Duration,
	onExit func(),
) {
	defer owner.release()
	if interval <= 0 {
		interval = ownerPollInterval
	}
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
			if owner.alive() {
				continue
			}
			// Re-check stop before acting: the owner can exit in the same
			// instant a legitimate /stop arrives, and the tunnel is already
			// gone in that case.
			select {
			case <-stop:
			default:
				onExit()
			}
			return
		}
	}
}
