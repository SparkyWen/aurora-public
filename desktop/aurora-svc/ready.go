package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// defaultReadyTimeout bounds how long /start waits for the tunnel to prove it
// came up.
//
// It was 12s, and that is the whole of the 2026-08-05 Windows failure: every
// connect ended in `tunnel_not_ready after 12s` with sing-box's own
// `open interface take too much time to finish!` as the last line of the tail.
// That line is sing-box's taskmonitor firing at C.StartTimeout (10s) — a
// WARNING, not an abort: the open keeps running. On Windows the thing being
// opened is a wintun adapter, i.e. a device install (SetupAPI, plus several
// 10-second registry waits inside wintun.dll), which on a cold machine, after a
// Windows update, or with security software hooking device installs routinely
// runs well past 10s. So the budget expired TWO SECONDS into a step the core
// itself considered slow-but-normal, and /start's give-up path killed a core
// that was still creating the adapter.
//
// Two things made that worse than a slow connect. It is Windows-only: Android
// and iOS are handed a ready file descriptor, Linux opens /dev/net/tun
// instantly. And it is a regression — before v1.0.10 replaced the fixed 1.2s
// settle delay with this handshake, /start never waited for readiness at all,
// so the same machine connected fine and the user experienced this as "Windows
// used to work".
//
// 45s is chosen to sit far above the point where sing-box is merely warning,
// because being patient costs a spinner while being early costs the connection
// — and killing mid-device-install can leave the half-created adapter behind
// (sing-tun derives the adapter GUID deterministically from the interface name,
// so the wreckage is exactly what the next attempt collides with), which turns
// one slow start into every subsequent start failing too.
//
// Waiting this long is only safe because /status and /stop no longer queue
// behind the wait — see Runner.snapshot and Runner.abortStart.
const defaultReadyTimeout = 45 * time.Second

// tunInterfaceNeverUpToken marks a readiness give-up where sing-box never
// reported the TUN interface coming up. Worth distinguishing because the two
// give-up shapes need different things from the user: an adapter that never
// appeared is a Windows/wintun problem (security software, a wedged device
// node, a reboot), while an interface that came up without the controller
// answering is a sing-box-side problem a reboot will not touch.
const tunInterfaceNeverUpToken = "tun_interface_never_up"

// tunInterfaceCameUp reports whether the child's own log says the TUN inbound
// finished opening the interface — sing-box logs `started at <name>` right
// after tun.New() returns. Matching on the interface name (rather than any
// "started" line) keeps this from being satisfied by some other component's
// startup chatter; the name is pinned by the Dart compiler to exactly this
// constant, see auroraTunInterfaceName.
func tunInterfaceCameUp(tail string) bool {
	return strings.Contains(tail, "started at "+auroraTunInterfaceName)
}

// clashProbe is how the app tells the privileged side where sing-box's Clash API
// will be this run. Both values are chosen per connection by the app (the port
// too — 9090 is Clash/mihomo/v2rayN's default and a bind failure is fatal to
// sing-box), so the service cannot guess them.
type clashProbe struct {
	Port   int    `json:"port"`
	Secret string `json:"secret"`
}

// pingClashAPI reports whether sing-box's Clash API is answering. Answering
// means the core finished starting: it binds the controller after the inbounds
// and outbounds are up.
func pingClashAPI(port int, secret string) bool {
	request, err := http.NewRequest(
		http.MethodGet,
		fmt.Sprintf("http://127.0.0.1:%d/version", port),
		nil,
	)
	if err != nil {
		return false
	}
	request.Header.Set("Authorization", "Bearer "+secret)
	client := &http.Client{Timeout: 1500 * time.Millisecond}
	response, err := client.Do(request)
	if err != nil {
		return false
	}
	defer func() {
		_, _ = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
	}()
	return response.StatusCode == http.StatusOK
}

// childExitedError marks an awaitReady failure that came from OBSERVING the
// child's own exit — i.e. this call already received the one buffered value
// off `exited`. It embeds error so it satisfies the error interface by
// delegating straight to the wrapped message; the type itself exists purely
// as a tag the caller can type-assert for.
//
// Why this matters: `exited` is `make(chan error, 1)` with exactly one
// producer and one value. Once awaitReady drains it here, NOTHING will ever
// send to it again for the lifetime of this child. If the caller's cleanup
// path (stopLocked) does not know that and re-selects on the same channel
// expecting a reap signal, it burns its whole fallback timeout every single
// time — not occasionally, deterministically — because the channel is
// permanently empty. Tagging the error lets startWithProbe skip that
// pointless wait: it already has definitive proof (the very waitErr it
// unwrapped to build this message) that the process is gone.
type childExitedError struct{ error }

// Cancellation belongs to this launch, not to the runner's next child. Keep
// the request channel local so a completed HTTP handler cannot stop a later
// connection when its context closes.
func startCancellation(cancel, requestDone <-chan struct{}) error {
	select {
	case <-cancel:
		return errors.New("start_cancelled: stopped while the tunnel was still coming up")
	case <-requestDone:
		return errors.New("start_cancelled: HTTP request ended while the tunnel was still coming up")
	default:
		return nil
	}
}

// awaitReady blocks until the tunnel demonstrably came up, demonstrably died, or
// the budget runs out — and names which.
//
// This replaces a fixed 1.2s "settle delay", which was a guess about how long a
// doomed start takes to die. On Windows the fatal failures (adapter creation,
// route/WFP installation, a taken controller port) land AFTER that window, so
// /start answered 200 and the failure surfaced later as a bare status flip with
// no reason anywhere.
//
// Called synchronously from startWithProbe with rn.mu already held — deliberately
// (see that function) — so this never needs to take the lock itself.
func (rn *Runner) awaitReady(exited <-chan error, cancel, requestDone <-chan struct{}, probe *clashProbe) error {
	budget := rn.ReadyTimeout
	if budget <= 0 {
		budget = defaultReadyTimeout
	}
	ping := rn.ClashPing
	if ping == nil {
		ping = pingClashAPI
	}
	deadline := time.After(budget)
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case waitErr := <-exited:
			return childExitedError{fmt.Errorf("sing-box exited: %s", describeExit(waitErr, rn.tailString()))}
		case <-cancel:
			// Deliberately NOT tagged the way childExitedError is: the child is
			// still alive on this path, so the caller's cleanup is the ordinary
			// kill-and-reap it already does for a give-up. Nothing needs to
			// branch on this, only to report it.
			return errors.New("start_cancelled: stopped while the tunnel was still coming up")
		case <-requestDone:
			return errors.New("start_cancelled: HTTP request ended while the tunnel was still coming up")
		case <-deadline:
			tail := rn.tailString()
			blame := ""
			if !tunInterfaceCameUp(tail) {
				blame = tunInterfaceNeverUpToken + ": "
			}
			// The verdict is matched against the WHOLE tail (tunInterfaceCameUp
			// above); only the copy handed to the user is clipped — see
			// errorTailLines.
			return fmt.Errorf(
				"tunnel_not_ready after %s: %s%s",
				budget, blame, lastLines(tail, errorTailLines),
			)
		case <-tick.C:
			if ping(probe.Port, probe.Secret) {
				// A probe can block while the caller cancels. A late healthy
				// response must not commit an already-abandoned connection.
				return startCancellation(cancel, requestDone)
			}
		}
	}
}
