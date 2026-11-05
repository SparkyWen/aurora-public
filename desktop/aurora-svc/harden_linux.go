//go:build linux

package main

import (
	"os"
	"os/exec"
	"syscall"
)

const singBoxBinary = "sing-box"

// hardenPrivilegedDir locks the directory the privileged side runs config out
// of to root only: an unprivileged process must not be able to swap the file
// between our write and sing-box's read.
func hardenPrivilegedDir(path string) {
	_ = os.Chmod(path, 0o700)
	_ = os.Chown(path, 0, 0)
}

// hardenTokenFile leaves the shared bearer token readable by local users.
//
// This mirrors the Windows ACL exactly — `(A;;FR;;;BU)` grants read to Builtin
// Users there. Both platforms therefore let any local process start/stop this
// machine's own VPN. On a personal single-user device that is the accepted
// trade; if it is ever tightened, tighten BOTH platforms, not one.
func hardenTokenFile(path string) {
	_ = os.Chmod(path, 0o644)
	_ = os.Chown(path, 0, 0)
}

// superviseChild is a no-op on Linux: unlike Windows' job object, the
// process-group + PDEATHSIG setup that ties sing-box's lifetime to ours has to
// be in SysProcAttr, which the kernel reads at fork/exec time — i.e. before
// cmd.Start(), not after. See prepareChild.
func superviseChild(*exec.Cmd) {}

// prepareChild must be called BEFORE cmd.Start() — SysProcAttr is read at
// spawn.
//
// Setpgid puts the child in its own process group, but nothing today reaps by
// group: Runner.stop() kills the single PID (cmd.Process.Kill()), never the
// group. That's harmless only because sing-box does not fork children of its
// own in this usage — PID and process group happen to have the same one
// member. If that ever stops being true, stop() would need a group kill to
// match.
//
// Pdeathsig is best-effort, not the unconditional guarantee Windows'
// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE gives: per Go's own SysProcAttr docs
// (golang.org/issue/27505), it fires when the OS THREAD that called fork
// exits, not when this process does, and the Go runtime can migrate
// goroutines off that thread. Low risk for a long-lived service, but not
// zero. What actually makes "a crashed service can't strand a live TUN
// interface" hold in the deployed configuration is systemd's default
// KillMode=control-group on stop/restart; Pdeathsig is only a second line of
// defense on top of that, not the mechanism doing the real work.
func prepareChild(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid:   true,
		Pdeathsig: syscall.SIGKILL,
	}
}

// wintun is Windows-only; nothing extra is required here.
func requiredRuntimeFiles(Paths) []string { return nil }
