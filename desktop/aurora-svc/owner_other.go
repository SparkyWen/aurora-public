//go:build !windows

package main

import (
	"errors"
	"syscall"
)

// posixOwner probes the owner with signal 0 — the portable "does this pid still
// exist" question.
//
// Unlike the Windows implementation this cannot pin the pid, so a recycled id
// could in principle look like the owner still running. The window is one poll
// interval wide and the consequence is a tunnel that stays up slightly too
// long, never one that is torn down early; on Linux the service is also root,
// so it can probe any pid on the box.
type posixOwner struct{ pid int }

func openOwnerProcess(pid int) (ownerProcess, error) {
	if pid <= 0 {
		return nil, errors.New("invalid owner pid")
	}
	if err := syscall.Kill(pid, 0); err != nil && !errors.Is(err, syscall.EPERM) {
		return nil, err
	}
	return &posixOwner{pid: pid}, nil
}

func (o *posixOwner) alive() bool {
	err := syscall.Kill(o.pid, 0)
	// EPERM means the process exists and we are not allowed to signal it —
	// which is still "alive". Only ESRCH means gone.
	return err == nil || errors.Is(err, syscall.EPERM)
}

func (o *posixOwner) release() {}
