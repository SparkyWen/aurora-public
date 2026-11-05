//go:build windows

package main

import "golang.org/x/sys/windows"

// windowsOwner holds a real handle on the owning process for as long as the
// tunnel is up.
//
// Holding the handle — rather than re-opening by pid on every poll — is what
// makes this immune to pid reuse: Windows will not recycle a process id while
// any handle to it is open, so "this handle is signalled" means THE process we
// were told about exited, not "some process with that number".
type windowsOwner struct{ handle windows.Handle }

func openOwnerProcess(pid int) (ownerProcess, error) {
	h, err := windows.OpenProcess(
		windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION,
		false,
		uint32(pid),
	)
	if err != nil {
		return nil, err
	}
	return &windowsOwner{handle: h}, nil
}

// alive asks the process object whether it has been signalled yet. A process
// handle becomes signalled exactly when the process terminates, so a zero-
// timeout wait is a non-blocking "is it still running?".
func (o *windowsOwner) alive() bool {
	if o.handle == 0 {
		return false
	}
	event, err := windows.WaitForSingleObject(o.handle, 0)
	if err != nil {
		// Cannot tell. Treat as alive: tearing a working tunnel down over an
		// unanswerable question would be worse than keeping it.
		return true
	}
	return event == uint32(windows.WAIT_TIMEOUT)
}

func (o *windowsOwner) release() {
	if o.handle != 0 {
		_ = windows.CloseHandle(o.handle)
		o.handle = 0
	}
}
