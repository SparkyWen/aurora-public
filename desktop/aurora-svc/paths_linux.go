//go:build linux

package main

// defaultStateBase is where the Linux service keeps everything it shares with
// the unprivileged app.
//
// Hard-coded on purpose. Linux has no %ProgramData%, and every plausible
// environment-derived alternative ($HOME, $XDG_STATE_HOME, $TMPDIR) is per-user
// — the service runs as root and the GUI as the logged-in user, so those two
// would resolve to different directories. That is exactly the fault that
// produced "config path outside allowed dir" on Windows. It matches the
// systemd unit's StateDirectory=aurora.
func defaultStateBase(string) string { return "/var/lib/aurora" }
