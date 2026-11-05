package main

import "time"

// auroraTunInterfaceName mirrors the Dart-side constant of the same name
// (app/lib/core/config_compiler.dart). The compiler pins tun.interface_name to
// it so this side can wait for the adapter to actually go away. Change both or
// neither.
const auroraTunInterfaceName = "aurora0"

// tunnelTeardownBudget bounds how long stopLocked's wait for the adapter to
// disappear runs before giving up. Preflight then allows one further bounded
// wait and proceeds with sing-box's create/open recovery for a leftover
// adapter; it does not refuse a start solely because the interface remains.
const tunnelTeardownBudget = 5 * time.Second

// waitForTunnelGone polls until the interface is gone or the budget expires.
//
// cmd.Wait() returning only means the process is reaped. On Windows the wintun
// adapter is removed after that, and the next start races it for the device —
// which is exactly the watchdog's self-heal sequence (stop → connect).
func waitForTunnelGone(name string, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !tunnelInterfaceExists(name) {
			return
		}
		time.Sleep(150 * time.Millisecond)
	}
}
