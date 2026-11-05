//go:build windows

package main

import "golang.org/x/sys/windows"

var (
	dnsapi                    = windows.NewLazySystemDLL("dnsapi.dll")
	procDnsFlushResolverCache = dnsapi.NewProc("DnsFlushResolverCache")
)

// flushResolverCache drops the machine's DNS answers.
//
// This is the one piece of sing-box's own teardown that a killed core cannot
// do for us. sing-tun calls windnsapi.FlushResolverCache() from NativeTun.Close()
// (see sing-tun tun_windows.go), and Close() only runs when sing-box exits
// through its signal handler. A crash or the service's forced-stop fallback
// bypasses that handler. Without this fallback flush, the Windows resolver
// can keep answering from a cache populated THROUGH the tunnel: overseas names
// resolved to addresses that are only routable via the proxy, handed out for
// their full TTL to a machine that no longer has a tunnel. From the user's
// chair that is exactly "Aurora still affects networking after I quit the app".
//
// Best effort by design: a missing export or a refused call must never fail a
// stop. `ipconfig /flushdns` is this same API with a console window attached.
func flushResolverCache() {
	if err := procDnsFlushResolverCache.Find(); err != nil {
		return
	}
	_, _, _ = procDnsFlushResolverCache.Call()
}
