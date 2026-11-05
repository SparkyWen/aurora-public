# Reliability notes

Each section describes a failure mode that actually occurred while building and running Aurora:
the symptom, the root cause, the fix, and how to tell whether it is happening again. They are
written to be useful without any other context. Most of the odd-looking code and comments in the
repository trace back to one of these.

The recurring themes are worth stating up front:

- "Connected" is a fact about a control plane. The user cares about the data plane.
- Health checks must resemble real traffic, or they certify things that do not work.
- Automatic recovery can amplify a problem as easily as it fixes one. Every remedy needs a bound,
  a confirmation step and an off switch for conditions it cannot fix.
- A wait without a follow-up action is not a fix. Decide what happens when the wait expires.
- Timeouts have provenance. Pick them by asking the dependency how long it thinks "slow" is.
- Cross-process contracts (paths, ports, names, encodings) must be derived from something both
  sides can compute independently, or carried as data.

The hard constraints that must not be violated are listed in [`CONTRIBUTING.md`](../CONTRIBUTING.md);
this document gives the evidence behind many of them. Architecture context is in
[`architecture.md`](architecture.md).

## Contents

1. Connected, but no traffic
2. One blocked address defeats every protocol on it
3. An entry used as an exit silently moves the public IP
4. Latency lies: urltest versus real throughput
5. A leg that passes the handshake and carries zero bytes
6. DoH connection reuse and the cold-start DNS storm
7. The sing-mux lock wedge
8. Hysteria2 zombie connections, UDP buffers, per-flow throttling, port hopping
9. `interrupt_exist_connections` belongs on selectors
10. Watchdog feedback loops
11. Physical network loss is not tunnel death
12. Probe results that mislabel the cause
13. IPv6 leaks
14. Windows: the privilege boundary
15. Windows: adapter lifecycle and timing
16. Windows: ownership, stop, cleanup, installer
17. Windows: encodings and ports
18. Apple extensions: leaks that outlive a session
19. Apple platform notes: keychain, container paths, state reporting
20. Home networks
21. Measuring honestly
22. Diagnosing a session: where to look

---

## 1. Connected, but no traffic

**Symptom.** The app shows a green "connected" state and nothing loads. The tunnel may also drop and
reconnect every minute or two, and every reconnect fails the same way.

**Root cause.** The platform status ("connected") only means that a tunnel object exists. Several
different things produced the same picture:

- every node of the contract was behind one address that was blocked (section 2);
- the tunnel was up but the selected leg carried no bytes (section 5);
- the extension reported "started" while the real start had failed, so a success event was logged
  before the platform had confirmed anything;
- on desktop, readiness was defined as "the Clash API answers". That proves the core process
  started and its controller bound. It proves nothing about whether the OS is handing traffic to
  the tunnel (a virtual switch, another VPN or security software can take the default route).

**Fix.**

- Keep a separate data-plane verdict from the control-plane state. The supervisor publishes
  `DataPlaneHealth` and the UI renders "connected, but no traffic" with an actionable reason, and
  clears stale "network verified" text.
- After asking the platform to start, wait until the platform actually reports connected
  (`ConnectFlow.awaitTunnelUp`). A reported disconnect or error is a failure with the extension's
  reason attached; silence is logged as unconfirmed and treated as "unknown", not as failure, so
  platforms that report state slowly are not punished.
- Record success events after the tunnel is confirmed up, not when the start call returns.
- Provide `/diagnose` on desktop so the one question that cannot be answered remotely ("what is on
  this machine's interface table, and is the adapter there?") has data behind it.

**Verify the egress, not connectivity.** For every route, check where traffic comes out, not only
that something comes out. `scripts/verify-egress.sh` starts a temporary sing-box per
selectable exit with `route.final` pinned to it and compares the reflected public address with the
expected one. A route that works but leaves from the wrong place passes every reachability test and
looks perfect; it is worse than a dead route. Run it after any change to nodes, roles, families or
chains.

**If it recurs.** Read the session timeline (`path-events.jsonl`, section 22). A `watchdog_probe_dead`
shortly after connect with the platform still "connected" is this class of problem. Then check, in
order: is the address reachable at all from this network (section 2), which leg is selected and what
is its throughput (sections 4 and 5), and does DNS inside the tunnel answer (section 6).

## 2. One blocked address defeats every protocol on it

**Symptom.** Connected, no traffic, repeated reconnects that never help. Each retry also tears down
the user's only physical default route, so the loop makes things worse.

**Root cause.** All nodes in the contract pointed at the same public address. Protocol diversity does
not help when the address is blocked: REALITY, Hysteria2 and Shadowsocks all die together. The block
was also one-directional, which makes it confusing to diagnose. A packet capture on the server showed
the client's SYN arriving, the server answering SYN-ACK, and the client retransmitting the SYN
because the reply never came back. The server also accumulated half-open (`SYN_RCVD`) connections.
Outbound worked, return traffic was dropped. From other networks the same server was perfectly
healthy, so the block was at the address level on one network path, not a server fault.

**Fix.**

- Make single-address contracts visible. Builders should warn when every node shares one address,
  and treat malformed extra-entry input as fatal rather than silently falling back to a
  single-address contract, which is exactly the situation being guarded against.
- Provide independent entries. A relay on a different network (the `relay` link kind) gives a path
  that does not share the blocked address. A relay should be locked down to forward to one
  destination, so it cannot be used as a general proxy.
- Provide CDN fronting (`vless-ws-tls`, `--cdn-domain` in `install.sh`). The client dials a CDN
  anycast address, so blocking the origin address does not matter unless the whole CDN is blocked.
  The compiler emits plain TLS with uTLS plus a WebSocket transport, no `reality`, and no `flow`
  (the Vision flow cannot run over WebSocket). The CDN proxy connects to the origin on the same port
  the client used, so pick one of the CDN's supported HTTPS ports that is free on the origin, and use
  the CDN's "Full" SSL mode if the origin uses a self-signed certificate. A CDN path is an entry, so
  section 3 applies to it.
- Stop pointless reconnect loops. After two consecutive reconnects that did not restore a single
  successful probe, stop and mark the session `deadUnrecoverable`. Changing the physical network
  refunds that budget. A rate limiter that merely slows an endless loop never reaches a verdict.

**Measurement pitfall.** A port that was never forwarded is expected to be closed. Testing the
one address on a port that was never mapped and concluding the node is down gives a false
alarm. Test the ports the node actually serves, from a machine on a different network.

**If it recurs.** From the affected network, bind probes to the physical interface (not the tunnel)
and try every port and protocol of every address in the contract, plus a CDN address. From a
different network, probe the same ports. If the failing set is "all ports of one address" while the
other network reaches it, the block is network-side and the answer is another entry, not another
protocol. Capturing on the server distinguishes "SYN never arrives" from "reply never returns".

## 3. An entry used as an exit silently moves the public IP

**Symptom.** Everything works and every reachability test passes, but the public address a site
sees is the relay's or the CDN origin's address, not the intended exit's.

**Root cause.** A node whose only job was to be a way in was declared as a terminal exit. After the
relay or CDN origin accepts the connection, the next hop is the machine's own `direct`, so the chain
stops there. This happened for a CDN-fronted path and for an emergency relay, and was only noticed
because someone checked the reflected address. A related wrongness is inferring structure: a node
with no `detour` was assumed to be a direct home exit, which put an overseas endpoint into the
"Direct" family where a latency-ranked pick could silently win.

**Fix.**

- Roles are explicit. `role: entry` is only an inbound path. It is excluded from every selector and
  urltest, from route-family membership and from the server list's address display. The builder
  creates a separate chained exit (`<exit>-via-<entry>`) whose `detour` is the entry, and only that
  exit is selectable. A terminal exit may only land on the intended exit address; anything else is a
  build error that names the fix, unless a contract explicitly opts in to a foreign exit.
- Never infer a route family from structure that cannot prove it. A missing `detour` means "no relay
  hop", not "home exit". Without an explicit family, a node is `unspecified`. Family is never
  guessed from an id prefix either (a prefix rule missed every entry that was not named the expected
  way).
- Keep roles authoritative in both builders and the app. Judge entries by `role`, never by name.
- Run the egress verifier (section 1) in CI or before release for every selectable exit.

**If it recurs.** Pin each exit in turn and compare the reflected public address with the expected
one (`scripts/verify-egress.sh --config <compiled.json> --expect <address>`). Any exit that
reports a different address is an entry that leaked into the selectable set.

## 4. Latency lies: urltest versus real throughput

**Symptom.** Pages stall and "load forever", although connection setup is quick and tiny requests
succeed. Every existing health check passes. Throughput through the tunnel is a small fraction of
a direct connection.

**Root cause.** `urltest` ranks members by one number: how quickly the first byte of a small probe
comes back. On a throttled path that number lies. A UDP-based protocol was allowed through the
handshake while sustained UDP throughput was throttled, so it had the lowest latency and the worst
throughput. It won every election, then loaded nothing. The health probe targets (empty 204
responses and a favicon of about 1 KB) finish within their timeout even at a couple of KB/s, so the
watchdog stamped the session "alive". When the watchdog eventually gave up and restarted, the restart
reset the selector, urltest re-elected the same leg by the same latency, and the loop repeated.

An unplugged tunnel was in fact slower than the working legs: the tunnel was not the problem, the
selected leg was.

**Fix.** Add a goodput gate (`GoodputGate`, `app/lib/core/goodput_gate.dart`): a node must move a real
payload at a real rate to keep its place.

- Read a fixed payload as a stream, stop at the byte target or the deadline, whichever comes first.
  A 2 KB/s leg then costs only the deadline.
- Demote only after two consecutive samples below the floor. One slow sample may be congestion or the
  probe competing with the user's own download. After a suspicious sample, re-check in seconds rather
  than minutes.
- An unreachable probe endpoint is not evidence against the path. Do nothing. A completely dead leg
  is the watchdog's job.
- A demoted node is cooled down (15 minutes), otherwise urltest elects it back immediately and the two
  fight.
- Restrict candidates to the active group, so a locked route family is never bypassed.
- Choose the floor from the measured distribution. Healthy paths swung between tens and hundreds of
  KB/s while sharing the link with real traffic; the broken one sat near 2 KB/s. The floor (16 KB/s)
  sits roughly 3x from either side. A first guess of 48 KB/s was too close to the healthy low-water
  mark and would have condemned a working path. This was only discovered by measuring on a device.

**Known limit.** The gate catches unusable, not suboptimal. An absolute floor cannot say "much slower
than the other leg".

**Other lessons.** Probes must look like real traffic (a probe made only of empty responses
certifies handshakes). A unit-tested component that nothing calls does not exist: a stability tracker
existed, with tests and documentation describing this exact problem, and was never wired into
production code. Check call sites, not just coverage.

**If it recurs.** Look for `goodput` events in the timeline, with the per-sample rate and which node
was measured. Pin each leg and download a few megabytes; compare rates. A leg with fast
time-to-first-byte and near-zero rate is this problem.

## 5. A leg that passes the handshake and carries zero bytes

**Symptom.** On one particular network, a QUIC-based leg works for tiny requests and then stalls;
browsers show certificate-style errors; the watchdog sometimes catches it and often does not.

**Root cause.** From certain networks, a UDP-based leg passes the QUIC handshake and a few small
exchanges, then carries nothing. The same configuration was healthy from a different network, the
same server was healthy when tested locally, and a second UDP leg with a different name worked, so
the fault was in that network path, not the server, not the SNI and not a global block. Changing the
source port did not help on this network.

The app compounded it. The goodput gate treated "ignore unreachable probe endpoints" too broadly and
also ignored the case where both probe endpoints failed to return even response headers within the
deadline. Most small watchdog probes still passed, so the watchdog saw the leg as alive, and the gate
refused to look. A user saw unloadable pages under a "healthy" indicator.

**Fix.** Distinguish silence from unreachability (`GoodputSample.stalled`):

- stalled: every attempt timed out or was cut before an answer arrived, including non-certificate
  handshake failures and "connection closed before full header";
- not stalled (so ignored): any HTTP answer at all, even 403 or 503, a certificate validation failure,
  or a DNS failure. These describe the far end or the resolver, not this path's throughput.

A stall counts as one measurement of zero bytes and still needs two in a row before demotion. The
timeline records `stalled: true`. After an upgrade, the first connection on such a network still
spends on the order of a minute and a half on the bad leg before demoting it, because the gate
state starts fresh on each start. Remembering "this leg is bad on this physical network" would
shorten that and has not been done.

**If it recurs.** Run isolated sing-box instances, one per leg, bound to the physical interface, each
doing a few small requests plus a few-megabyte download with a hard time cap. Compare small-request
success with bytes transferred. "Small requests pass, download gets 0 bytes" on exactly the
UDP leg is this problem. Test the same leg from a second network to separate path from server.

## 6. DoH connection reuse and the cold-start DNS storm

**Symptom.** Right after the tunnel (re)starts, the first health round is judged dead about half the
time. Connection failures cluster in busy hours. The watchdog then switches legs or restarts the
tunnel, which restarts the cold start.

**Root cause.** The resolver for tunnelled names is DNS over HTTPS through the proxy. A previous fix
set `Connection: close` on it so that each query would go through the current proxy selection (see
the end of this section for the race it addressed). That made every cache miss open its own TLS
connection, and each of those needed its own session to the exit plus a handshake to the relay: three
layers of handshake multiplied by the number of concurrent queries. After a start, every program on
the machine re-resolves at once. In measurements a single start opened one DoH connection per distinct
name (hundreds in total), most queries failed, and the median resolution took seconds. The watchdog's probe must resolve names first, so it
queued behind that storm and timed out. The remedy (change leg or restart) cleared the DNS cache and
dropped sessions, recreating the storm. The environment (a congested hop at peak hours) was only the
trigger. The program built the loop.

**Fix.**

- Use a single reused DoH connection with every query multiplexed over it. Keep DoH, certificate
  verification, proxy detour and answer caching. Measured side by side on the same link, a cold-start burst of a
  hundred distinct names resolved with a median roughly two to three times slower with per-query
  connections than with reuse, and the first-round health probe passed in every run with reuse but
  only about two thirds of runs without it. Plain
  UDP DNS was fast but shares a single connection too and sends names in clear, so it was not chosen;
  DNS over TLS dials one connection per in-flight query and reproduced the storm.
- Add a settle period. After the active node changes for any reason (watchdog, the core's own
  urltest re-election, group switch, user), the next verdict waits 11 seconds (`selectionSettle`), because
  a shared dial stuck on the old node can delay the first query on the new one for up to its own
  10 s deadline, which is longer than the probe's 8 s timeout. A network change does not wait: the core
  resets its network and builds a fresh connection pool.
- Do not "fix" leg changes by clearing DNS on every switch. The core's network reset also clears the
  answer cache, which is precisely the cold start being avoided.
- Probe DNS inside the tunnel directly (section 7).
- Answer names that can never resolve publicly (`.local`, private reverse zones, service-discovery
  names, the tunnel's own address) with NXDOMAIN locally. They were observed going to the proxied
  resolver, each paying a multi-hop round trip with no possible answer, and timing out in the queue
  with real queries when the link degraded.

**Cost that remains, with bounds** (`tests/upstream-dns/`). Reuse reintroduces a narrow race: the
connection being dialled at the instant of a group switch lands on the old node and lives until the
next switch. A dial stuck on a dead node blocks new queries until its own deadline (10 s), and a
silently dead shared connection fails queries until the first query's deadline, after which the
transport resets. These are bounded and pinned by a test using the real sing-box DNS client, selector
and urltest against a local TLS server.

**If it recurs.** In the core log, count DoH connections opened per start and DNS failures in the
first 20 seconds. In the timeline, `connect_ok` followed within about 25 s by `watchdog_probe_dead`,
repeatedly, is the signature. Check that the DNS server entry has no `Connection: close` header.

## 7. The sing-mux lock wedge

**Symptom.** In the evening peak, new connections on one leg hang for tens of seconds or minutes;
in one episode, DNS for the whole machine died silently for several minutes with almost no errors
logged, then a burst of failures all at once when it released. The watchdog said "alive". Stopping the
tunnel sometimes took so long the extension process was judged poisoned.

**Root cause.** Shadowsocks legs used sing-mux. With default parameters it reuses only sessions that
have no active streams and otherwise dials a new one. The client serializes this under one
client-wide lock, and inspecting existing sessions needs each session's HTTP/2 write lock. So:

- all new connections on the leg queue and dial one at a time;
- any session blocked on a write (full send buffer, stalled link) freezes the whole leg. On a TCP leg
  this ends when HTTP/2 health checks close the connection (about 45 s). On a QUIC leg nothing bounds
  it, because a QUIC stream write beyond one packet blocks until the data is actually sent and `Close`
  does not wake it. One episode lasted 9 minutes;
- closing the client takes the same lock, so shutdown stalls;
- the DoH dial waits behind it, and the HTTP/2 transport makes concurrent requests wait for an
  in-flight dial without honoring their own deadlines, so machine-wide DNS died. Switching legs did
  not help, because the stuck dial belonged to the old leg.

The watchdog was blind because its probe names were in the system cache and its traffic reused
already-open sessions.

**Fix.**

- Shadowsocks outbounds never carry `multiplex`. The compiler ignores a contract's `multiplex: true`
  (older clients still read it, so builders keep emitting it) and sets `udp_over_tcp: true` instead,
  because UDP used to ride inside mux sessions over TCP and relays may only forward TCP to the home
  node. Without mux, each connection dials on its own with its own deadline.
- The watchdog sends a fresh-name DNS query straight to the tunnel DNS address each round. Any
  well-formed answer, including NXDOMAIN, counts as alive. No answer in 4 s is retried once; no
  answer within 8 s, or SERVFAIL, counts as dead. A locally unusable socket counts as "not measured",
  never as dead. This is a backstop for stuck legs from any cause.
- The cost is about a third of a second on isolated new connections, more connections to the relay
  and exit, and one extra DNS query per watchdog round. Concurrent bursts are slightly faster.

**If it recurs.** Look for connections whose dial started minutes after the context was created,
for a burst of `exchange failed` errors on release, and for `closeService` exceeding its bound. Check
the compiled config: no Shadowsocks outbound should contain `multiplex`, all should contain
`udp_over_tcp`. In the timeline, `watchdog_probe_dead` with the `tunnel_dns` probe failing is the new
signature.

## 8. Hysteria2 zombies, UDP buffers, per-flow throttling, port hopping

**Zombie connections.** A QUIC connection that had been running for a while stopped delivering any
data, while keepalives were still answered, so the idle timeout never fired and the client kept
reusing it. A freshly started instance on the same path worked immediately, and the server had not
received the streams. The shape matches carrier-side per-flow UDP rate limiting. The client cannot
cure the underlying network behaviour; it must stop it dragging other things down. That is why
anything that can block on a QUIC write must have another route (no mux over it, DNS probing, the
goodput gate). Diagnose by starting a second, new instance and comparing: if the new one is healthy
the old one is a zombie.

**Per-flow throttling and source-port hopping.** Some carriers throttle UDP per flow (per 4-tuple).
A controlled experiment on one leg, with two instances running side by side, showed the effect:
the non-hopping instance alternated between working and long stalls (the longest lasted tens of
seconds, and probe success dropped sharply), while the instance that changed source port every 10 s
consistently reached the shaper limit with only brief stalls. Single-flow throughput collapsed while
the hopping client was unaffected. A new source port is a new flow with a fresh allowance.

Why this needs no server change: with `server_ports` set, the sing-box Hysteria2 client uses a
hopping packet connection. Every `hop_interval` it opens a new local UDP socket and sends to a
port chosen at random from the list, keeping the old socket for one more period to receive. The
server's QUIC stack follows the new source address without path validation. So a single entry
`"<port>:<port>"` is enough to change the 4-tuple on every hop, and the compiler passes the contract's
`server_ports` and `hop_interval` through (and fails to compile if they are malformed: a mistyped
range is a dead leg and it is better not to connect).

**Only advertise ports verified reachable from outside.** The client hops blindly with no per-port
health check, so one blocked port in the list is a periodic outage, and a fully blocked range is a
dead leg. If a destination port range is mapped on the server (for example by redirecting a UDP
range to the listening port), packets must still be able to reach the server. A cloud provider's
firewall in front of the VM may allow only the listening port, in which case nothing sent to the rest
of the range ever reaches the NIC. So: open the range at the provider, verify from outside by
capturing on the server's interface that probes to several ports arrive, and only then advertise the
range. Until then the contract lists only the listening port (this is what `ServerBundle` emits).
Destination-port hopping is not a cure on every network; on at least one carrier network a UDP leg
passed the handshake and carried nothing regardless of source port (section 5), so keep the other
protocols in the group.

**UDP socket buffers.** QUIC needs large socket buffers. The Linux default maximum (208 KB) throttles
quic-go under bursty load: single streams pass while real browsing stutters, which is difficult to
diagnose afterwards. `install.sh` writes `net.core.rmem_max` and `net.core.wmem_max` of 16 MB to
`/etc/sysctl.d/99-aurora-node.conf`. If a Hysteria2 leg stutters but a single download is fine,
check the values on the server (and the client's equivalent limits) first.

## 9. `interrupt_exist_connections` belongs on selectors

**Symptom.** The VPN "drops for a moment and recovers", repeatedly, with no leg actually failing. The
timeline shows constant switching inside a family.

**Root cause.** The option was set on `urltest` groups. A urltest re-elects whenever another member
becomes faster beyond its tolerance, and nearly all re-elections are jitter, not a member going down.
With the option set, each one kills every existing connection. One group kept flipping between three
protocols, one of which handshakes fastest while carrying nothing, so it kept winning.

**Fix.** Set `interrupt_exist_connections: true` only on the `selector`. A selector change is a
decisive act: the user pinned a family, a safety transaction moved traffic, or the goodput gate
demoted a leg, and existing connections on the old member should end. urltest groups must not carry
the flag. Both group types have regression-guard comments in `config_compiler.dart`.

**If it recurs.** Search the compiled config for the flag: it must appear on selectors only. In the
timeline, many short-interval switches with no `watchdog_probe_dead` or `goodput_demote` events
means a re-election storm.

## 10. Watchdog feedback loops

Several incidents were the same pattern: an automatic remedy that makes the original condition worse.

- The restart resets the selector, urltest re-elects the same bad leg, the watchdog restarts again.
  Fix: goodput gate with cooldown (section 4), and a bounded restart budget with no restarts for
  conditions a restart cannot fix.
- The remedy rebuilds a cold DNS state (section 6). Fix: settle period, probe DNS directly.
- The remedy disturbs a process that is still shutting down. A restart that begins before the old
  core has stopped collides with it. Fix: recovery only begins after a confirmed `disconnected`
  (not `error`, which only says an error happened), under a recovery lock, with cancellation
  generations so a late task from an old session can never mark a new session healthy or start a
  tunnel after the user pressed disconnect. Late probe results are discarded against the session
  and network epoch.
- An old watchdog or goodput sample finishing after a reconnect must not modify the new session.
  Generation checks everywhere.
- A user choosing "automatic" must stay automatic after a contract refresh. The choice "none" and
  "auto" were both stored as null and the default then locked a family on every refresh. Persist
  `'auto'` explicitly.
- After the core process actually exits (not just becomes unhealthy), there must be a recovery path
  that does not depend on the old watchdog. Desktop connection recovery keeps the connection
  intent, retries a bounded number of times (spacing growing from seconds to tens of seconds), does
  not refund the budget for a short-lived success, and is cancelled by manual disconnect.
- A transient failure of the status endpoint must not tear down supervision of a core that is still
  forwarding. Keep the connected state when the controller of the known core still answers, and
  still report an error when the service and core are both unreachable.

## 11. Physical network loss is not tunnel death

**Symptom.** Hotel Wi-Fi drops for a minute. Afterwards the app says the preferred route is
unavailable, then the other route is unavailable too, and nothing recovers until the user reconnects
manually, sometimes hours later.

**Root cause.** A chain: the Wi-Fi drops. All probes time out. After confirmation the supervisor
demotes every leg of the family into its cooldown, so no leg can be selected, and the UI blames the
locked family. With nothing left to switch, it restarts the tunnel. Shutting down needs to send close
frames and cannot with no network, so the bounded stop exceeds its limit and the extension process is
marked poisoned and exits. The app's reconnect attempts are then refused by the OS ("no network
available") one after another (a retry plus three recovery rounds, all burned within seconds). When
the network returned, nothing was listening: retry budgets only reset on manual connect or two
minutes of stable connection, the network signature poller stopped with the session, and the old
signature reader returned "no addresses" as an empty string, which was ignored, so the same lease
dropping and coming back did not count as a change.

**Fix.**

- Make "offline" a first-class state in the physical network signature (`physical_network.dart`),
  distinct from "no change". The signature excludes the tunnel interface by name and by exact host
  address, and common virtual bridges.
- While offline, the supervisor does not probe, charge, demote, switch or restart; it cancels pending
  death confirmations and shows "your network is disconnected" without naming a route.
- When the network returns: refund the abandonment budget and the hourly restart cap, clear goodput
  cooldowns accumulated during the outage, and re-verify.
- Desktop recovery uses its own network monitor. With no network, it does not queue retries (it says
  it will reconnect when the network is back); on return or change it resets its budget and
  reconnects after a short delay, polling once more first so it does not use a stale "online" reading.
- Surface the OS's verdict when it refuses a start (for example the last disconnect error from the
  tunnel manager) and translate "no network available" into plain language.
- Keep the extension's self-heal (poison, exit, relaunch). It is correct when needed; it was simply
  triggered too often by pointless restarts.

**Known blind spots.** The signature excludes virtual adapters by name pattern and the tunnel by exact
address; an unrecognised virtual adapter that holds an address but has no upstream still counts as
physical, and detection then falls back to the old behaviour (offline not recognised) rather than
misreporting. It judges "has a usable address", not "has internet": a captive portal counts as online.

## 12. Probe results that mislabel the cause

- A tunnel-mode health probe that fails with "connection terminated during handshake" does not mean TLS
  is broken. In tunnel mode, the local peer is sing-box, which accepts the local connection, fails to
  dial the remote and closes the local one. That is a proxy-chain failure. In a long
  run of field data, every TLS-class probe result was this closed-handshake case and none was a
  certificate validation failure. Classify them separately: the user message for a closed handshake says the
  proxy chain could not connect, and certificate failures keep their own wording.
- Real certificate failures are reported by the runtime as a different exception class than a closed
  handshake. Reproduce both with local servers. A handshake that was closed must not claim a bad
  certificate, and an untrusted certificate must be refused and classified.
- Do probes concurrently with a shared window and keep each endpoint's classification. A serial probe
  that burns the whole budget on the first slow site turns every outcome into one synthetic timeout
  and discards the earlier successes. A mixed result ("some sites reachable") should say so.
- A request that has received headers but never finishes the body is still running after a plain
  `Future.timeout` completes. Use abortable requests with a deadline over the whole response, and do not
  close shared clients that other callers use.
- An HTTP response of any status is evidence that the path works; do not count a challenge page as
  transport failure.
- Local service calls must check status codes and body shape. A 401 on `/status` read as "stopped" and a
  401 on `/stop` read as success, which would claim a tunnel was down when it was not.
- A client taking over a running desktop tunnel needs its control coordinates (port, secret). Return
  them to an authenticated caller; if an old service cannot, say so and ask for a reconnect rather than
  guessing the default port, which may belong to another proxy product.
- A disconnect pressed while a start request is still in flight must cancel it; the service records a
  stop generation before reading the request body and rejects requests older than it after taking the lock.
  Otherwise stop succeeds and the late start then creates a tunnel while the UI says "disconnected".
- Discovery and contract refresh: race all candidate origins under one budget; a candidate wins only after
  it parses, verifies and passes the upgrade gate. Re-check a cached lease's validity at the end, not only
  at the start.

## 13. IPv6 leaks

**Symptom A: image batches fail while the page text loads.** Browsers with their own encrypted DNS
resolve AAAA records around the tunnel's DNS rules. The IPv6 reject rule came after `sniff`. Once the
TUN has accepted and sniffed a connection, sing-box can only close it, and browsers treat a closed
connection as a final error instead of falling back to IPv4. Separately, `reject` silently turns into
`drop` after many hits in a short window, and a page with a hundred parallel image requests crosses
that threshold.

**Fix.** Put the IPv6 reject rule first, before `sniff`, with `method: default` and `no_drop: true`. A
pre-match reject returns an immediate TCP reset or ICMP unreachable and the browser falls back at once,
while IPv6 is still captured and cannot leak. Removing IPv6 from the TUN also fixed the symptom but
gave up capture, so it was not chosen on mobile. (An early hypothesis blamed the UDP protocol; forcing
other protocols, disabling QUIC and lowering MTU each failed to fix it. Isolating by removing one
variable at a time found it.)

**Symptom B: IPv6 escapes on Windows.** The contract blocked IPv6 through a route rule, yet the TUN was
also given an IPv6 address. sing-tun installs its kernel-level "block all IPv6 egress" filter only when the
TUN has no IPv6 address. So the kernel backstop was never installed. Route rules only reject IPv6 that
entered the tunnel; on-link traffic, traffic during a network switch, and sockets bound to a physical
adapter's address all went straight out. A second effect: with a v6 address configured, sing-tun
also set the TUN's IPv6 DNS server, and the first route rule rejected every query sent to it, so
each resolution waited for a fallback to the IPv4 server, on slow machines an extra timeout on every
lookup.

**Fix.** `ipv6_mode: block` means the desktop TUN gets no IPv6 address (`ConfigCompiler._tunInbound`).
Mobile platforms are untouched because they create their interface through the OS.

**If it recurs.** On Windows check that the firewall layer contains the block-IPv6 filter while the
tunnel is up, and that the TUN has no IPv6 address. Test with a site reachable only over IPv6, with the
tunnel up and the physical adapter holding a v6 address.

## 14. Windows: the privilege boundary

**Symptom.** Every connect fails with `403 config path outside allowed dir`, on every machine and with
every contract.

**Root cause.** The service runs as LocalSystem and the app runs as the logged-in user. `%APPDATA%` is a
per-user variable, so the two processes computed different directories for the same agreed location. The
service's allowlist was correct; the mistake was sending a path across a boundary where the path has no
single meaning.

**Fix.** Never pass a filesystem path across the privilege boundary: send the bytes. `/start` takes
`{"config": "<sing-box JSON>"}` and the service writes it into its own directory (under
`%ProgramData%`, access-restricted to system and administrators). Any location both sides must agree on
derives only from machine-wide variables (`%ProgramData%`), and a test fails if the service ever reads a
per-user variable. The same trap exists on Linux with `$HOME` and `$XDG_*`, which is why the Linux state
base is the fixed `/var/lib/aurora`.

Related defects found at the same time, all cross-process contracts and failure visibility:

- A token read into memory at service start and cached forever means a token written after installation
  never takes effect (401 until reboot). Read it on each request. Same on the client.
- An install routine that returns early when the service already exists leaves it pointing at a deleted
  executable after the old folder is removed. Re-point an existing registration and restart it.
- Child process output thrown away means "exit status 1" is the whole story. Capture it into a ring
  buffer and a log file, and report an early exit synchronously.
- Run the child with an explicit working directory (otherwise its cache file lands in the system
  directory) and in a kill-on-close job object so a service crash cannot orphan a tunnel.
- Run installable software from a protected directory, not from a user-writable one, since a privileged
  service launching a binary from a user-writable location is an elevation hazard. Ship an installer.
- Do not call a platform "done" because it builds. Add a CI job that runs the unit tests, a cross-compile
  and an installer compile before tagging, and record an acceptance run on a real machine.

## 15. Windows: adapter lifecycle and timing

**Symptom.** Every start fails with "tunnel not ready after 12s" on Windows only. The log shows a warning
exactly 10 seconds after the start: "open interface take too much time to finish".

**Root cause.** The readiness window (12 s) was only 2 s longer than sing-box's own threshold (10 s) for
declaring a step "slow but still running". That warning is not a failure; startup continues. On Windows,
creating the virtual adapter is a device install (device node creation plus several registry waits inside
the driver library). It routinely exceeds 10 s on a cold machine, after a system update, or when security
software hooks device installation. The readiness probe is the controller API, which binds only after
every inbound is up, so it sat behind the slow step. At 12 s the service gave up and killed a core that was
still alive, mid-device-install.

The damage compounds. sing-tun derives the adapter GUID deterministically from the interface name, so the
next attempt asks for the same GUID that the killed attempt left half created. It collides with the
wreckage ("file already exists") or pays another round of registry waits. One slow start becomes every
start failing until reboot. This looked like "it worked before" because the readiness wait was introduced
later to replace a short fixed delay; before that, nothing waited and slow adapter creation was invisible.

**Fix.**

- Readiness budget 45 s (`defaultReadyTimeout`). It must stay far above 10 s. The cost of waiting is a
  spinner; the cost of giving up early is a failed connection and a dirty machine.
- A long wait must not hold up other requests. `/status` reads a lock-free snapshot published at each state
  transition, and `/stop` aborts a launch in progress instead of queueing behind it. Otherwise a slow start
  freezes the tray (no timeout on its calls), the app's status poll (3 s timeout, read as "service dead"),
  and the OS service manager's stop handler, which holds up system shutdown.
- Say which kind of giving up it was. If the core never reported the interface up, tag the error
  `tun_interface_never_up` and tell the user the adapter could not be created (restart, or temporarily
  disable network protection in security software). If the interface came up but the controller did not
  answer, tell them the controller port may be taken. Two causes, two next steps.
- Tests pin the invariants: the budget outlasts the core's slow-start warning, the adapter-never-came-up
  message appears only when true, `/status` answers during a start, `/stop` aborts a start.

**Leftover adapters and phantom devices.** The fixed adapter name (`aurora0`) exists so that stop can wait
for the adapter to actually disappear and so that preflight can detect leftovers. The Dart constant
(`auroraTunInterfaceName`) and the Go constant in `tunnel_gone.go` must change together. Further findings:

- Preflight used to refuse to start if a leftover `aurora0` existed. That made a self-healing situation
  permanent, because the library cleans orphaned devices (or opens the existing adapter) on creation, so the
  start being refused was the only thing that would have cleared the wreckage, and nothing else on the
  machine deletes it. Now preflight waits a short grace (2 s) and then starts anyway, recording that it
  began from a dirty slate so a following failure can say so.
- The ordinary adapter enumeration call omits down interfaces that still exist. Sampling showed
  stretches where the normal listing said the adapter was gone while the flag-all listing still showed it
  Down and the device manager still had a phantom or a device in a problem state. Query with the flag that
  includes all interfaces and match by name without filtering by state.
- Even the all-interfaces view is not a deletion barrier for the underlying device. After a killed core,
  the phantom was still present half a minute later, and a precise device removal reported success quickly
  but the adapter list took longer than a 15 s check to clear (and was completely clear only minutes later).
  The driver library queues orphan cleanup asynchronously at exit and its own interface-ready wait is 15 s,
  which matches the observed problem-state window. Do not claim a fixed time for removal; do not treat
  `stopped` as proof that the device is gone.
- Publish "running" only after the readiness check passes. Publishing it at process creation made the
  client believe a new core was ready while it was still creating the adapter, and the client kept polling
  a stale controller from the previous core. Convert the service's `starting` into the client's
  `connecting`, clearing stale control coordinates.
- A "recovered" claim needs strict criteria: authenticated controller answer, the listening process is the
  new core, session identity unchanged across the check, several independent endpoints, the connection's
  route is the tunnel, and the reflected address matches the expected one. A looser check (process exists,
  service running, one site loads) declared recovery while the tunnel was not yet taking over. Report the
  elapsed time to the first fully verified state honestly; it can be tens of seconds to minutes.
- A script claiming a route is wrong if its own check is wrong. Sorting a hash table did not sort as
  expected in an older PowerShell and made every route check report false. Keep failed runs on record and
  fix the check, not the verdict.

## 16. Windows: ownership, stop, cleanup, installer

**Symptom.** After quitting the app, the machine still behaves oddly; uninstall leaves things behind; with
a wired connection, traffic meant for Wi-Fi leaks to the cable; a machine shows "connected" but cannot
reach anything; an occasional multi-line 500 appears that a reconnect cures.

**Root causes and fixes.**

- **The tunnel's lifetime was not tied to the app's.** The tunnel is a core process owned by a system service
  that captures all routing, and the only thing that stopped it was the tray menu's Quit. Task Manager, a
  crash, logoff, an installer's process kill during upgrade, and closing the window when the tray icon failed
  to install all left a system-owned full-capture tunnel with no UI. Fix: `/start` carries `owner_pid`;
  `/status?owner_pid=` can re-claim a live tunnel; when the owner process exits the service stops the
  tunnel. On Windows it holds a real process handle, so pid reuse cannot fool it. The CLI deliberately
  sends none, because it connects and exits and its tunnel must outlive it. Multiple GUI instances fighting
  over ownership are prevented by a per-session single-instance mutex taken before the UI engine starts.
- **The core was always killed, never asked.** sing-box does all cleanup in its signal handler. Terminating
  the process skips removing the adapter cleanly and, notably, flushing the resolver cache. The cache held
  answers resolved through the tunnel (foreign sites often resolve to addresses that only work via the
  proxy), so the machine kept following tunnel-era answers after Aurora was gone: "I quit it and the
  network is still wrong". Fix: stop sends the graceful signal (a console control event on Windows, via a
  console the service allocates for itself because a service has none; every step best-effort), waits 3 s
  and only then kills. Whichever path is taken, finish with a resolver cache flush. Cleanup after an
  unexpected core exit uses the same routine and waits for the old adapter before another start is
  allowed.
- **Egress interface choice.** With `auto_detect_interface`, outbound sockets bind to whichever interface the
  OS calls default, which is the cable whenever it is plugged in, whatever the user wants. Offer a setting
  that sets `default_interface` instead. The two options are mutually exclusive in sing-box (the latter is
  ignored when the former is on), so the compiler emits exactly one. The interface name must come from the
  same source sing-box's own interface monitor uses (Go's interface listing, via `/diagnose`), not from
  another runtime's naming.
- **Observability gap.** "Connected" came from the controller answering. Add `/diagnose` (interface table, adapter
  presence, owner, full core log tail), include it in the diagnostics bundle, and trim user-facing errors to
  the last two lines of core output (the rest stays in the log and `/diagnose`).
- **Uninstall hygiene.** Wait for the service to actually reach STOPPED, retry service deletion, delete
  both machine-level and user-level state, and remove the autostart entry. An installer that kills
  processes by image name globally also kills unrelated programs with the same name; identify processes
  by full install path and verify identity on an opened handle. If the service fails to stop or times
  out, the upgrade or uninstall must fail rather than replace or delete files from under a live service.
- **Cancellation.** Cancelling a client's HTTP request must cancel the start that request began,
  through preflight, readiness and the legacy settle branch; a handler that completed earlier must never
  stop a newer session's tunnel.
- **A first adapter creation can fail on a freshly killed core** ("a device attached to the system is not
  functioning") and succeed on retry. The client retries a one-shot start failure once; the retry is
  bounded, not a loop.

## 17. Windows: encodings and ports

- **UTF-8 versus latin-1.** Adapter friendly names are localized and failure details contain localized
  system error strings. An HTTP client that decodes a body without a declared charset as latin-1 produces
  mojibake, and the user then picks a name from that list to hand back to the core as an interface name. A
  mangled name never resolves. Fix both sides: the service declares `charset=utf-8`, and the client decodes
  raw bytes as UTF-8 regardless of headers. The bug was found by a test using a non-ASCII adapter name; an
  ASCII-only test would have passed forever. Keep such test data non-ASCII (use escapes in source).
- **Control port conflict.** The default port of the controller API (9090) is also the default of several
  other proxy tools. If another program holds it, sing-box fails to bind and exits (a failed controller
  bind is fatal), which looks like "the core failed to start". Pick a fresh free loopback port and a fresh
  secret for every connection and carry both in the session so a re-attaching client can recover them.
  Do not write the port or secret into shareable diagnostics.
- **Do not claim readiness for a service whose only evidence is "service is running".** See section 1.

## 18. Apple extensions: leaks that outlive a session

On macOS the system extension process outlives sessions. Each session creates a new provider object, but
the process and everything the Go runtime in it holds continue. Three incidents were one root cause in
different places.

**Fixed command port leaked.** The core's command server listens on a fixed local port. A disconnect hung in
the core's shutdown because one outbound would not close, taking tens of seconds. The cleanup that releases
the listener was written against the provider instance, but a new session gets a new instance, so the
leaked listener was unreachable from any Swift reference. Every following start failed with "address
already in use", permanently, because the port is fixed. Reported success events were logged although the
extension was failing every start.

**The cache file lock.** The same stuck shutdown kept a bounded-database file lock. After the port was
fixed, the next exclusive resource in line took over: every start failed with "initialize cache-file:
timeout". An early theory blamed a server-side device limit because the problem started after connecting
from a second device. A controlled experiment separated cause from correlation: with everything else
unchanged, killing the extension process made the next start succeed in seconds. Concurrency was then
tested directly (several independent clients on one account all connected), confirming no device limit.

**Lessons and fixes.**

- Patching one leaked resource at a time does not converge. The leak is the whole core instance, so the
  recovery unit is the whole process (`TunnelProcessHealth`, shared by macOS and iOS).
- Any bounded shutdown that times out marks the process poisoned instead of logging a line. After stop
  completes, a poisoned process exits (the tunnel is already down, the OS relaunches on next connect, the
  user never sees it). A start in a poisoned process is refused immediately rather than waiting out the
  database timeout; a start failure in a process that has already run a session also restarts it.
- Prevent restart loops, the one subtle part, and pin it with tests: the first start failure of a fresh
  process never restarts it (it can only be a bad config or no network, and restarting would loop);
  a port held by another process never restarts it (suicide cannot free someone else's port); each
  process self-heals at most once even if the late stop and the next start both want to.
- Command server as a process-level singleton, since the port is process-wide.
- Close the service and the listener with independent bounded waits on separate threads. The listener close
  does not take the service lock, so it can free the port even while the service close is stuck; chaining
  them on one thread was the original leak.
- In the app, require the platform to report connected after a start, give the state a brief grace period
  because it initially reads disconnected, and lengthen the pre-reconnect wait for disconnect to exceed the
  longest observed shutdown.
- A bounded wait needs a follow-up action: giving up the wait is the moment to decide whether the process
  is still usable.
- A long-running process turns every single leak into a permanent failure. Process-per-session
  platforms hide this class of bug until a platform that reuses the process shows it.
- Rapid stop/start is where it shows: when stop exceeds the shutdown limit and the app starts again
  immediately, the start meets the poisoned process. The app's connect flow retries once after waiting
  a few seconds for the platform to settle; a success reported while the tunnel is down does not count.

## 19. Apple platform notes: keychain, container paths, state reporting

- **Keychain accessibility.** Secure storage on macOS uses an accessibility class that permits reads after
  first unlock, so background and recovery paths work while the screen is locked. The wrapper includes the
  accessibility attribute in its lookup, so an item stored under a different class looks like a missing
  item. A migration must run before any read, write or delete, once, with no parallel retries, and it
  should fail loudly rather than treat a failed migration as "no contract stored". Remember that a
  remote SSH session often sees a locked keychain while the GUI session sees it unlocked; signing and
  notarization steps that need the keychain must run in the GUI session or unlock it explicitly. Do not
  alter keychain access control or export credentials to work around it.
- **The runtime's environment is empty on iOS.** The Dart VM on iOS exposes an empty process environment,
  so code that derived a directory from `HOME` silently failed and the timeline logged nothing. Obtain
  container paths from the platform (a path provider) and inject them. A unit test that injects an
  environment cannot catch this; verify on a device.
- **Container access for diagnostics.** The device tooling can copy files only from certain container
  domains. Put anything you may need to retrieve under the application's Library or Documents, not
  the shared group root.
- **File permissions in build output.** A packaging script running under a restrictive `umask` produced
  resource files with owner-only modes. Once the extension was copied into place owned by root, the system
  tools complained. Normalise permissions in a build copy before signing (directories 0755, files 0644,
  executables 0755, keep private embedded data private, never follow symlinks), never in the already
  activated bundle.
- **Same-version reinstall.** Re-notarizing and installing the same version number can leave the OS with the
  previous extension copy (same identifier, same process). Increase the version to force a real replacement.
- **Source sync is not deployment.** A machine with up-to-date sources can be running an app weeks old.
  Check installed versions against expectations before attributing a problem to a "current" build.
- **Iteration of the command client.** A transport interruption must not cause a storm of re-dials (one
  incident saw dozens of dials from a single interruption), late callbacks from an old stream must not restart a
  replacement connection, repeated starts must not create duplicates, a dial completing during stop must be
  closed, and old state must be isolated by a generation counter. All of this is in the shared command client
  tests.
- **Memory limits.** The iOS extension runs with a hard memory limit; the Go runtime is configured with an
  aggressive GC and a soft memory limit, and peak use sits close to it. Measurements of CPU cost per MB
  showed the multiplexing and GC settings were not the bottleneck on a congested link. Do not add per-
  connection buffers there without measuring.

## 20. Home networks

A home node is an unusual server: it sits behind a residential router, has a changing public address and a
provider that dislikes inbound services.

- **Inbound 80 and 443 are commonly blocked by the ISP** even when the router's port-forwarding table shows
  them mapped and the router is happy. That is why `install.sh --home` defaults to other ports (and offers
  an explicit override). Do not conclude a node is down because 443 is closed; test the ports that are
  actually forwarded.
- **Hairpin tests lie.** Testing your own public address from inside the LAN usually goes through the router's
  NAT loopback or short-circuits before the ISP filter, and can report ports as open that the internet cannot
  reach. A test from the node itself against its own public address is not evidence. Test from an outside
  host (a cheap VPS is enough).
- **UPnP mappings go stale after a DHCP change.** A maintenance job that re-asserts port forwards to a
  hard-coded LAN address will, after the node gets a new lease, keep refreshing forwards to an address that
  no longer holds it. The router accepts such a request, so the log says success while every inbound port
  is dead. Resolve the machine's current LAN address on each run; fall back only to an explicit override, never
  a guessed literal; log "skipped, no LAN address" when it cannot be determined. A DHCP reservation for
  the node is still the best fix, with UPnP as the convenience on top.
- **A router with UPnP on is often a deployment dependency.** Do not recommend disabling it before manual
  port forwards exist.
- **Dynamic DNS.** The public address changes. Clients should dial a DNS name that a maintenance timer keeps
  current (`--host` with a Cloudflare or DuckDNS token in `install.sh`). The record must be DNS-only, not
  proxied: the node serves raw TCP and UDP, and a proxied record returns the CDN's address and handles only
  a subset of ports. Use a dedicated record on one zone, a token scoped to editing DNS on that zone, and
  keep the TTL short. Do not create an IPv6 record for a node without IPv6 egress.
- **Dual stack.** The default design blocks IPv6 at the client. A node without IPv6 egress should not be
  advertised over it.
- **Server-side scanners.** Logs of failed REALITY or Shadowsocks handshakes ("invalid connection",
  "bad header", "salt not unique", "bad timestamp") are usually public internet scanners. A modest number
  of rejected connections from the user's own carrier addresses can be a client abandoning a slow dial.
  Timestamp errors with delays of tens of seconds mean the outer connection stalled and buffered data
  arrived late, a consequence of a stalled link, not a cause. Clock skew over about 30 seconds does cause
  Shadowsocks 2022 failures, so make sure the node and client clocks are synchronised (on Windows the time
  service may be stopped).
- **The relay side.** A relay's firewall and any cloud security group must both allow the entry ports. Verify
  externally. Source-port hopping needs no extra ports; destination-port ranges do (section 8).

## 21. Measuring honestly

Many wrong conclusions in the history came from the measurement, not the system.

- **Controlled experiments beat correlation.** Two events that arrive together (a second device connecting,
  then failure) are not a cause until one is changed alone. Killing one process and seeing the failure go
  away took ten seconds and ended a long theory.
- **Run diagnostic instances beside production, not instead.** A separate sing-box with a local mixed
  inbound, outbound sockets bound to the physical interface, and a hard time limit leaves the running
  tunnel and routes untouched. Alternate the variants within a run, repeat, and report ranges, not one
  number.
- **Bind to the interface explicitly.** With a tunnel up, an unbound test measures the tunnel. Use
  `curl --interface` (which really sets the interface binding) on macOS; a bare `timeout` command does not
  exist there and a failed command swallowed by `||` produces a table that is entirely red and means
  nothing.
- **External vantage for server health.** Decide whether the server is healthy from another network. A
  client's lossy network proves nothing about the server.
- **Time zones and clocks.** Logs from different components use different zones. Normalise before correlating
  and check clock skew between nodes.
- **Peak hours.** Congestion at specific times of day is real and cannot be fixed by the client; the client
  can only avoid amplifying it. Judge a fix after it has run through the busy period, and do not claim
  success for a change that has only been observed off-peak.
- **Do not write a failed or incomplete run as a pass.** Record the criteria used, keep a partial report as
  partial, and keep verification claims separate from "unit tests pass".
- **Report limits.** A unit test proves a coded condition; it does not prove a device recovered. Real-device
  behaviours (adapter lifecycle, firewall filters, carrier throttling) should be listed as verified or
  not verified.
- **Check the shape of the failure's data.** A failing request whose DNS, TCP and TLS times are all zero
  means the stages were never reached; it is not "instant DNS".

## 22. Diagnosing a session: where to look

1. **Timeline** (`path-events.jsonl` in the application support directory; on iOS under the app container's
   Library). Look for `connect_ok`, `watchdog_probe_dead` (with per-member latencies and which probes
   failed), `watchdog_restart`, `hard_failure_demote`, `goodput` and `goodput_demote`,
   `network_changed`, `physical_network_up`, and recovery events. Time zone is UTC.
2. **Core log.** Dial errors, DNS failures, "take too much time to finish" warnings. A warning is not a
   failure.
3. **Extension / service log.** Apple: extension breadcrumbs (start, stop bounds, process poisoned),
   plus the system's unified log for refused starts. Desktop: `/diagnose` (interface table, adapter, owner,
   core tail) and the service log.
4. **Compiled config checks.** No `multiplex` on Shadowsocks, `udp_over_tcp: true`, the flag
   `interrupt_exist_connections` on selectors only, DoH without a `Connection: close` header, IPv6 reject
   before `sniff`, no IPv6 address on desktop TUN when blocking, exactly one of `auto_detect_interface` or
   `default_interface`.
5. **Egress.** `scripts/verify-egress.sh` against the compiled config.
6. **Isolated per-leg runs** bound to the physical interface (section 21), small requests plus a bounded
   download, from this network and from another one.
7. **Server side.** Services listening, firewall and cloud security group, a capture on the NIC when
   packets might not arrive, clock skew, scanner noise versus real clients.

If the cause is not in the list above, add a section here once you have it: symptom, root cause, fix,
and how to recognise it again.
