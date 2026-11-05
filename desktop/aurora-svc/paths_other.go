//go:build !linux

package main

import "path/filepath"

// Windows resolves %ProgramData% before reaching here; this is the last resort
// for a box so broken it has neither, and for the macOS dev machines. Keep
// state beside the binary rather than guessing at a user directory the service
// cannot see.
func defaultStateBase(exeDir string) string {
	return filepath.Join(exeDir, "state")
}
