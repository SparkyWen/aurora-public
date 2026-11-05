//go:build !windows

package main

// flushResolverCache is a no-op off Windows.
//
// The leftover it exists to clear is specific to the Windows DNS Client
// service, which owns a machine-wide cache that survives the process that
// populated it (see netclean_windows.go). Linux has no equivalent
// unconditionally-present cache: sing-tun does not install one, and a box
// running systemd-resolved keeps its cache keyed to the link whose settings
// went away with the interface. Shelling out to `resolvectl flush-caches` on
// every stop would spawn a process for nothing on most boxes, so this side
// stays empty and honest rather than superstitious.
func flushResolverCache() {}
