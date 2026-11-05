# DNS connection-reuse regression

Run `bash tests/upstream-dns/run.sh` from the repository root. Set `GO=/path/to/go` to pick a toolchain; any extra arguments (for example `-race`) are passed to `go test`. The script resolves the existing `go.mod` / `go.sum` inside `core/` and compiles only this directory's test files. It copies no dependencies, does not modify sing-box, and adds no app code to the bind-only core.

The test reads the compiler's `expected-smart` / `expected-global` JSON and uses sing-box's own JSON decoder and HTTPS DNS constructor to build a real DNS client, TLS and HTTP/2 transport, plus a real selector and URLTest. The only network boundary is a local HTTPS server on a random port with controlled dialing: no TUN device, no credentials, no public network. URLTest is driven through its public history interface so that real member election runs, with the external-connection interrupt option disabled to keep the production config semantics.

It covers four things:

- **Reuse.** 20 concurrent distinct cache misses open exactly one DoH connection; an identical question hits the answer cache. This is what keeps the machine from being overwhelmed when every app re-resolves at once after the tunnel (re)starts. With `Connection: close`, every miss paid its own three-hop TLS handshake, and the first probe round after a cold start died on DNS in 3 of 8 runs.
- **Bound on the cost (1).** The connection being dialled at the moment of a group switch is established after the switch and leaks to the old node (upstream race: the interrupt group only registers a connection once the dial returns). It has just been dialled successfully, and it lives only until the next group switch, because sing-box unconditionally closes internal connections that pass through the group on a switch.
- **Bound on the cost (2).** A shared dial stuck on a dead node makes new questions wait together, but only until that dial's own DNS deadline (10 seconds in production, 3 seconds in the fixture). Questions after that follow the node the selector currently points at.
- **Bound on the cost (3).** If the shared connection silently stops answering (no group switch, no network change, and upstream sends no HTTP/2 health-check ping), every question fails until the first question's own deadline expires. The transport then resets and the next question dials again. With one connection per query, a stuck connection only hurts the single question on it.

Bounds (2) and (3) are both longer than the watchdog's 8 second probe timeout. After the watchdog changes the selection itself, it therefore waits a full 11 seconds before judging (`VpnSessionSupervisor.selectionSettle`); otherwise a dial stuck on the old node would make the first verdict on the new node fail for no reason.

Also kept: a certificate hostname mismatch must fail.

The DNS request deadline cannot be configured through the sing-box 1.13.14 JSON schema. The shorter deadline used in the test only isolates the fixture and does not change the production config.
