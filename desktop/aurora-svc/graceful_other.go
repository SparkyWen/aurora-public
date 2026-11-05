//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

// signalGracefulStop asks sing-box to shut itself down.
//
// SIGTERM is one of the three signals sing-box's cmd_run.go listens for, and
// its handler is what closes the TUN — removing the device, the routes it
// installed and any firewall state — before the process goes away. A bare
// Kill() skips all of that and leaves the OS to notice on its own.
//
// The signal goes to the child itself rather than to its process group even
// though prepareChild puts it in one (see harden_linux.go): sing-box spawns no
// children of its own in this usage, so pid and group have the same single
// member, and signalling the pid keeps this honest about what it actually
// reaches. Returns whether the signal was delivered; the caller bounds the wait
// and kills on expiry.
func signalGracefulStop(cmd *exec.Cmd) bool {
	if cmd == nil || cmd.Process == nil {
		return false
	}
	return cmd.Process.Signal(syscall.SIGTERM) == nil
}
