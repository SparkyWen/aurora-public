// aurora-svc: a tiny privileged helper that starts/stops the official sing-box
// binary with TUN privileges on Windows, so the Flutter app never needs UAC per
// connection (installed once as a service, normally by the installer).
//
// Security boundary: localhost-only, bearer token, and — since the app hands
// over the config itself rather than a path — nothing the caller says is ever
// interpreted as a filesystem location. The config the privileged side runs is
// written by the privileged side, into a directory only SYSTEM/Administrators
// can write.
package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// svcListenAddr is the fixed localhost endpoint the Flutter app talks to.
const svcListenAddr = "127.0.0.1:53421"

// maxConfigBytes bounds a /start body. A compiled Aurora config is ~4 KB; the
// ceiling only exists so a wedged caller cannot make the service allocate.
const maxConfigBytes = 4 << 20

// defaultSettleDelay is how long start() waits before declaring success. A
// config sing-box rejects dies within milliseconds, so this turns the most
// common failure into a synchronous, quotable error instead of a red dot.
const defaultSettleDelay = 1200 * time.Millisecond

// gracefulStopBudget is how long a stop waits for sing-box to leave on its own
// before killing it. Its teardown is device removal plus a few registry waits,
// i.e. the same order of work as coming up; three seconds covers the ordinary
// case without letting a wedged core hold the tray, the SCM's stop handler or
// an uninstaller hostage.
const gracefulStopBudget = 3 * time.Second

// staleAdapterToken tags a failure that began over an adapter left behind by an
// instance we no longer track. The app matches on it (connect_flow.dart) to
// tell "try again" apart from "reboot".
const staleAdapterToken = "stale_adapter_adopted"

// errorTailLines is how many of sing-box's last lines an error carries to the
// user.
//
// It used to carry all 8 KB the tail buffer holds, which is what produced the
// wall of red the user reported on 2026-08-14: five or six lines of core log
// where one sentence was needed. The full tail is not lost — it stays in
// %ProgramData%\Aurora\logs\sing-box.log and is served whole by /diagnose. This
// only bounds the copy that ends up in a dialog.
const errorTailLines = 2

// lastLines keeps the final n non-empty lines of s, marking the truncation so
// nobody reads a clipped tail as the whole story.
func lastLines(s string, n int) string {
	if s == "" || n <= 0 {
		return s
	}
	lines := make([]string, 0, 8)
	for _, line := range strings.Split(s, "\n") {
		if trimmed := strings.TrimRight(line, "\r "); strings.TrimSpace(trimmed) != "" {
			lines = append(lines, trimmed)
		}
	}
	if len(lines) <= n {
		return strings.Join(lines, "\n")
	}
	return "…\n" + strings.Join(lines[len(lines)-n:], "\n")
}

// parseVerb interprets argv the same way on every platform.
//
// Defect 2, reproduced live on 2026-08-03: running `aurora-svc --help` to see
// its usage started the HTTP server and began listening on 127.0.0.1:53421.
// Every platform's main() switched on os.Args[1] with no default case, so an
// argument that matched none of the explicit cases fell straight through to
// the foreground-serve fallback below the switch — a typo'd verb silently
// launched a privileged daemon. Centralising the decision here means every
// platform's main() gets the fix by construction, instead of by remembering
// to add a default case to three separate switches.
//
// Bare invocation (len(args) <= 1) and the verb "run" both mean "serve in the
// foreground" everywhere (on Windows "run" additionally means "do the SCM
// handshake first" — that distinction is the caller's to make, not this
// function's): bare invocation is how a human debugs by hand, "run" is what
// every service manager's ExecStart passes (main_linux.go's unitTemplate,
// app/linux/packaging/aurora-svc.service; the Windows SCM equivalent in
// service_windows.go). extra lists any additional verbs this platform accepts
// on top of that — Linux and Windows pass "install", "uninstall"; the
// macOS-only dev build (main_other.go) passes none, because it does not
// implement either.
func parseVerb(args []string, extra ...string) (verb string, ok bool) {
	if len(args) <= 1 {
		return "", true
	}
	verb = args[1]
	if verb == "run" {
		return verb, true
	}
	for _, e := range extra {
		if verb == e {
			return verb, true
		}
	}
	return verb, false
}

// printUsage writes a one-line usage message to stderr naming the verbs this
// platform accepts, instead of silently reaching the foreground-serve
// fallback — see parseVerb.
func printUsage(prog string, extra ...string) {
	verbs := append([]string{"run"}, extra...)
	fmt.Fprintf(os.Stderr, "usage: %s [%s]\n", prog, strings.Join(verbs, "|"))
}

// Guard authenticates requests. It is the ONLY thing standing between a local
// process and a SYSTEM-privileged sing-box, so the token is mandatory.
type Guard struct {
	// TokenSource returns the currently-provisioned token. It is a function,
	// not a string, because the token must be re-read per request — see
	// [fileToken].
	TokenSource func() string
}

func (g *Guard) authorize(r *http.Request) bool {
	const prefix = "Bearer "
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, prefix) {
		return false
	}
	want := ""
	if g.TokenSource != nil {
		want = g.TokenSource()
	}
	if want == "" {
		return false // never authorize before a token is provisioned
	}
	got := h[len(prefix):]
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

// tailBuffer keeps the last n bytes written to it, so a failed start can quote
// what sing-box actually said instead of "exit status 1".
type tailBuffer struct {
	mu  sync.Mutex
	buf []byte
	max int
}

func newTailBuffer(max int) *tailBuffer { return &tailBuffer{max: max} }

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > t.max {
		t.buf = t.buf[len(t.buf)-t.max:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	if t == nil {
		return ""
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	// Stripped here, on READ, not in Write: Write's sinks also include the log
	// file (see startWithProbe's io.MultiWriter), and that file is a
	// diagnostic artifact a human reads in a terminal — arguably FINE with
	// sing-box's original colour. Stripping only the copy this type hands back
	// keeps the log file untouched while every caller of tailString()/String()
	// (describeExit's several call sites, awaitReady's timeout/exit branches)
	// gets clean text automatically, with no per-caller strip() to forget.
	// Reading on the accumulated buffer, rather than per Write() call, also
	// means a CSI sequence split across two separate Write()s (unlikely given
	// exec.Cmd's pipe copy, but not impossible) is still one contiguous slice
	// by the time stripANSI sees it. See Defect 1, reproduced live 2026-08-03.
	return strings.TrimSpace(string(stripANSI(t.buf)))
}

// Runner owns the single sing-box child process. All methods are safe for
// concurrent use.
type Runner struct {
	SingBoxPath string        // <install dir>\sing-box.exe
	WorkDir     string        // child cwd — keeps cache.db out of C:\Windows\System32
	ConfigPath  string        // where WE write the config we are about to run
	LogPath     string        // rolling copy of the child's stdout+stderr
	SettleDelay time.Duration // 0 → defaultSettleDelay
	// CheckTimeout bounds the pre-start `sing-box check`. 0 → defaultCheckTimeout.
	CheckTimeout time.Duration
	// RequiredFiles must all exist before a start is attempted (Windows:
	// wintun.dll). Naming the missing one beats "the core did not come up".
	RequiredFiles []string
	// ReadyTimeout bounds awaitReady. 0 → defaultReadyTimeout.
	ReadyTimeout time.Duration
	// ClashPing is the readiness probe. Test seam; nil → pingClashAPI.
	ClashPing func(port int, secret string) bool
	// OpenOwner takes a handle on the process that asked for the tunnel, so it
	// can be torn down when that process goes away. Test seam;
	// nil → openOwnerProcess. See owner.go for why this exists at all.
	OpenOwner func(pid int) (ownerProcess, error)
	// OwnerPollInterval is how often that handle is checked. 0 → ownerPollInterval.
	OwnerPollInterval time.Duration
	// TunnelGone waits for the TUN interface to disappear. Test seam;
	// nil → waitForTunnelGone.
	TunnelGone func(name string, timeout time.Duration)
	// TunnelExists reports whether the TUN is in the OS interface table, even
	// if it is down. Test seam;
	// nil → tunnelInterfaceExists.
	TunnelExists func(name string) bool

	mu     sync.Mutex
	cmd    *exec.Cmd
	config []byte // the config the live child was started with
	exited chan error
	// tail is an atomic.Pointer, not a plain field guarded by mu, because
	// tailString() is documented as safe to call with or without mu held (see
	// its doc comment). A plain *tailBuffer field written under mu but read via
	// tailString() would only happen to be race-free for as long as every
	// caller of tailString() is known to run inside a mu-holding critical
	// section — true today (awaitReady is its only caller, invoked synchronously
	// while startWithProbe holds mu) but not something the compiler or a future
	// caller (e.g. a status/log endpoint that deliberately wants to peek at the
	// tail without contending on mu) can be trusted to preserve. The atomic swap
	// makes the promise actually true instead of true by coincidence of the
	// current call graph.
	tail    atomic.Pointer[tailBuffer]
	lastErr string

	// staleAdapter records that preflight found an aurora0 left behind by an
	// instance we no longer track, and started anyway (see preflight.go). Kept
	// so a start that then fails can say so, instead of leaving the user to
	// guess whether the wreckage was relevant.
	staleAdapter bool

	// ownerStop ends the goroutine watching the owning process; ownerGen makes
	// a watcher that fires late harmless, by letting it check whether the
	// tunnel it was watching is still the tunnel that is up. Both guarded by mu.
	ownerStop chan struct{}
	ownerGen  int64
	// ownerPID mirrors the claimed pid for lock-free readers (/diagnose), for
	// the same reason `snapshot` exists: nothing that only reports state may
	// queue behind a launch holding mu.
	ownerPID atomic.Int64

	// snapshot is what /status reports, and it is deliberately NOT behind mu.
	// startWithProbe holds mu for the whole readiness wait — up to
	// defaultReadyTimeout, which is now long enough for a Windows adapter
	// install — and a /status that queued behind that lock would be worse than
	// the slow start it is reporting on: AuroraBridgeSvc's poller reads its own
	// 3s timeout as "the service died" and flips the UI to error, and
	// desktop_shell's tray/status calls set no timeout at all. Deriving the
	// answer from rn.cmd/rn.lastErr is what forced the lock; publishing it on
	// every transition instead means /status answers immediately, in whatever
	// state the runner is in.
	snapshot atomic.Pointer[runnerState]

	// cancelStart is closed by abortStart to end a readiness wait in flight.
	// Also not behind mu, for the same reason: /stop (and the Windows SCM's
	// stop handler, which calls runner.stop() directly) must be able to
	// interrupt a launch rather than queue behind it — a service that took 45s
	// to acknowledge a stop would hang system shutdown.
	cancelStart atomic.Pointer[chan struct{}]

	// Invalidates starts still reading HTTP bodies or waiting for mu when a
	// stop arrives, before they can install their readiness cancel channel.
	stopGeneration atomic.Uint64
}

// runnerState is an immutable snapshot. Credentials are exposed only through
// authenticated /status; state() and shareable diagnosis never return them.
type runnerState struct {
	state, detail string
	probe         *clashProbe
}

// publish records what /status will report from now on. Every place that
// changes rn.cmd or rn.lastErr must call it — state() no longer derives the
// answer from those fields, precisely so it never has to take mu.
func (rn *Runner) publish(state, detail string) {
	rn.snapshot.Store(&runnerState{state: state, detail: detail})
}

// armCancel installs a fresh cancellation channel for the launch about to wait,
// and returns it. Fresh per start: a channel closed by a previous stop would
// abort the next launch instantly.
func (rn *Runner) armCancel() <-chan struct{} {
	ch := make(chan struct{})
	rn.cancelStart.Store(&ch)
	return ch
}

// disarmCancel drops the channel once the wait is over, so a later stop of an
// already-running tunnel does not try to close it a second time.
func (rn *Runner) disarmCancel() { rn.cancelStart.Store(nil) }

// abortStart ends a readiness wait in flight, if there is one. Safe to call
// with or without mu, and safe to call when nothing is starting.
func (rn *Runner) abortStart() {
	// Swap rather than load-then-close: two concurrent stops would otherwise
	// both see the same open channel and the second close would panic.
	if ch := rn.cancelStart.Swap(nil); ch != nil {
		close(*ch)
	}
}

func (rn *Runner) settleDelay() time.Duration {
	if rn.SettleDelay > 0 {
		return rn.SettleDelay
	}
	return defaultSettleDelay
}

func (rn *Runner) tunnelGone() func(string, time.Duration) {
	if rn.TunnelGone != nil {
		return rn.TunnelGone
	}
	return waitForTunnelGone
}

func (rn *Runner) tunnelExists() func(string) bool {
	if rn.TunnelExists != nil {
		return rn.TunnelExists
	}
	return tunnelInterfaceExists
}

func (rn *Runner) openOwner() func(int) (ownerProcess, error) {
	if rn.OpenOwner != nil {
		return rn.OpenOwner
	}
	return openOwnerProcess
}

// armOwnerLocked binds the live tunnel's lifetime to pid. Caller holds mu.
//
// pid <= 0 means "no owner" — that is the contract `aurora-cli connect` relies
// on, since it starts a tunnel and exits on purpose. A failure to take the
// handle is also treated as no owner: refusing to connect because we could not
// set up a convenience watchdog would be trading a working VPN for a tidy one.
func (rn *Runner) armOwnerLocked(pid int) {
	rn.disarmOwnerLocked()
	if pid <= 0 {
		return
	}
	owner, err := rn.openOwner()(pid)
	if err != nil {
		return
	}
	stop := make(chan struct{})
	rn.ownerStop = stop
	rn.ownerGen++
	rn.ownerPID.Store(int64(pid))
	gen := rn.ownerGen
	go watchOwner(owner, stop, rn.OwnerPollInterval, func() {
		rn.stopOwnedTunnel(gen)
	})
}

// disarmOwnerLocked forgets the owner and ends its watcher. Caller holds mu.
// Bumping the generation here (not only on arm) is what makes a watcher that
// was already past its stop check a no-op instead of a stop of somebody else's
// tunnel.
func (rn *Runner) disarmOwnerLocked() {
	if rn.ownerStop != nil {
		close(rn.ownerStop)
		rn.ownerStop = nil
	}
	rn.ownerGen++
	rn.ownerPID.Store(0)
}

// stopOwnedTunnel tears the tunnel down because the process that asked for it
// is gone.
//
// Deliberately takes mu the ordinary way instead of calling abortStart first
// like /stop does: this runs on a background goroutine nobody is waiting for,
// so waiting out a launch in flight costs nothing — while aborting one would
// cancel a start that a DIFFERENT, live client had just asked for.
func (rn *Runner) stopOwnedTunnel(gen int64) {
	rn.mu.Lock()
	defer rn.mu.Unlock()
	if rn.ownerGen != gen || rn.cmd == nil {
		return
	}
	rn.stopLocked()
	rn.lastErr = ""
	rn.publish("stopped", "")
}

// claimOwner lets a client that did not start this tunnel take responsibility
// for it — the app relaunching and adopting a session that outlived it.
//
// TryLock, never Lock: this is reached from /status, and /status must answer
// immediately in every state (see the snapshot field). A launch in flight holds
// mu for its whole readiness wait, and blocking here would reintroduce exactly
// the freeze that snapshot exists to prevent. Missing a claim costs nothing —
// the app polls /status once a second, and a start of its own arms the owner
// directly.
func (rn *Runner) claimOwner(pid int) {
	if pid <= 0 {
		return
	}
	if int64(pid) == rn.ownerPID.Load() {
		return
	}
	if !rn.mu.TryLock() {
		return
	}
	defer rn.mu.Unlock()
	if rn.cmd == nil {
		return // nothing running to be responsible for
	}
	rn.armOwnerLocked(pid)
}

// start keeps the legacy behaviour for callers that cannot say where the Clash
// API will be: preflight, launch, and treat "still alive after the settle
// delay" as success.
func (rn *Runner) start(config []byte) error {
	return rn.startWithProbe(config, nil)
}

// startWithProbe runs sing-box against config. It is idempotent for an
// identical config (the app re-asks on every connect) and *applies* a changed
// one, because silently keeping the old tunnel while reporting success is how
// a user ends up on a route they did not choose.
//
// probe == nil reproduces the old fixed-delay behaviour (for callers on an
// older contract that never learned about clash_probe). probe != nil switches
// to awaitReady: poll the Clash API / watch for an early exit, whichever comes
// first, instead of guessing a settle window.
func (rn *Runner) startWithProbe(config []byte, probe *clashProbe) error {
	return rn.startOwned(config, probe, 0)
}

// startOwned is startWithProbe plus the caller's own process id, so the tunnel
// can be torn down if that process goes away — see owner.go. ownerPid == 0
// means "nobody owns this", which is what the headless CLI wants: it connects
// and exits by design.
func (rn *Runner) startOwned(config []byte, probe *clashProbe, ownerPid int) error {
	return rn.startOwnedGuarded(config, probe, ownerPid, nil, nil)
}

func (rn *Runner) startOwnedGuarded(config []byte, probe *clashProbe, ownerPid int, allowed func() bool, requestDone <-chan struct{}) error {
	rn.mu.Lock()
	defer rn.mu.Unlock()
	// Armed here, at the top, not just around the readiness wait: preflight
	// runs `sing-box check` and gets its own multi-second budget, and a stop
	// that landed in THAT window would otherwise queue behind everything this
	// function goes on to do. Armed early, the abort is already visible by the
	// time the wait starts, so it gives up at its first look instead of at its
	// deadline.
	cancel := rn.armCancel()
	defer rn.disarmCancel()
	// Check after arming: a stop racing this check either changes the generation
	// before it, or closes this launch's cancel channel afterwards. Rejecting
	// the obsolete request must not change a newer child's status or stop it.
	if allowed != nil && !allowed() {
		return errors.New("start_cancelled: request was cancelled or superseded by stop")
	}

	if rn.cmd != nil && rn.cmd.Process != nil {
		if bytes.Equal(rn.config, config) {
			// Same tunnel, possibly a different client asking for it (the app
			// restarted and re-issued its connect). Ownership still has to
			// transfer, or the tunnel would keep pointing at a dead process and
			// be stopped the moment its watcher next looks.
			//
			// Only ever an UPGRADE on this path: a caller that names no owner
			// must not be able to un-own a tunnel somebody else is responsible
			// for. `aurora-cli connect` against an already-running GUI session
			// would otherwise silently disable the very teardown this exists
			// for — quitting the app would stop cleaning up again, which is the
			// bug, not a feature of the CLI's fire-and-forget contract.
			if ownerPid > 0 {
				rn.armOwnerLocked(ownerPid)
			}
			return nil
		}
		rn.stopLocked()
	}

	// A child and an adapter can exist before sing-box finishes opening the
	// tunnel. Keep /status responsive without advertising a usable session
	// during preflight or the readiness wait. Empty detail denotes progress.
	rn.publish("starting", "")
	rn.staleAdapter = false
	if err := rn.preflight(config); err != nil {
		rn.fail(err.Error())
		return errors.New(rn.lastErr)
	}
	// Checking a config may outlive the HTTP request or a concurrent /stop.
	// Do not create a TUN for a connection its caller has already abandoned.
	if err := startCancellation(cancel, requestDone); err != nil {
		rn.fail(err.Error())
		return err
	}
	if err := os.MkdirAll(rn.WorkDir, 0o700); err != nil {
		rn.fail("create work dir: " + err.Error())
		return errors.New(rn.lastErr)
	}

	tail := newTailBuffer(8 << 10)
	sinks := []io.Writer{tail}
	logFile, err := openLogFile(rn.LogPath)
	if err == nil {
		sinks = append(sinks, logFile)
	}

	cmd := exec.Command(rn.SingBoxPath, "run", "-c", rn.ConfigPath)
	cmd.Dir = rn.WorkDir
	cmd.Stdout = io.MultiWriter(sinks...)
	cmd.Stderr = cmd.Stdout
	// SysProcAttr (process group + PDEATHSIG on Linux) is read by the kernel at
	// fork/exec, so this must run before Start(), not after like superviseChild.
	prepareChild(cmd)
	if err := cmd.Start(); err != nil {
		if logFile != nil {
			_ = logFile.Close()
		}
		rn.fail(describeExit(err, tail.String()))
		return fmt.Errorf("start sing-box: %s", rn.lastErr)
	}
	// Tie the child's lifetime to ours: if the service is killed or crashes,
	// Windows tears the tunnel down too, instead of stranding the machine
	// behind a TUN interface nothing owns any more.
	superviseChild(cmd)

	exited := make(chan error, 1)
	rn.cmd, rn.config, rn.exited = cmd, config, exited
	rn.tail.Store(tail)
	rn.lastErr = ""
	// Armed before the readiness wait, not after it: mu is held for the whole
	// wait, so a client that dies mid-launch would otherwise be un-noticeable
	// until the wait finished — up to 45s of a machine tunnelling for a process
	// that no longer exists.
	rn.armOwnerLocked(ownerPid)
	go func() {
		waitErr := cmd.Wait()
		exited <- waitErr
		rn.mu.Lock()
		if rn.cmd == cmd { // still the current child — record why it went away
			rn.recordExitedLocked(describeExit(waitErr, tail.String()))
		}
		rn.mu.Unlock()
		if logFile != nil {
			_ = logFile.Close()
		}
	}()

	if probe != nil {
		// The lock stays held while we wait. That is deliberate: a second
		// /start arriving mid-launch must queue behind this one, not race it
		// for the TUN device. awaitReady only reads exited/cancel/probe and
		// calls rn.tailString() (atomic, needs no lock of its own) — it never
		// calls rn.stop() or anything else that would try to retake rn.mu and
		// deadlock against the lock we are holding right now. /status and /stop
		// are the two callers that must NOT queue here, and neither takes mu on
		// its way in any more (see Runner.snapshot and Runner.cancelStart).
		if err := rn.awaitReady(exited, cancel, requestDone, probe); err != nil {
			if _, alreadyDead := err.(childExitedError); alreadyDead {
				// awaitReady already drained exited's one buffered value, so
				// it has definitive proof the child is gone — stopLocked's
				// kill-then-wait-for-reap would just Kill() a corpse and then
				// select on a channel nothing will ever fill again, burning
				// its full 5s fallback for no reason on every fast-failure
				// path. Skip straight to the state cleanup stopLocked would
				// otherwise do after that pointless wait.
				rn.recordExitedLocked(err.Error())
			} else {
				// stopLocked, not stop(): stop() takes rn.mu, which we
				// already hold — calling it here would deadlock forever.
				// The process is presumed still alive here (awaitReady gave
				// up on the timeout branch, not the exit branch), so the
				// kill-and-reap is genuinely needed.
				rn.stopLocked()
				rn.fail(err.Error())
			}
			return errors.New(rn.lastErr)
		}
		rn.publishRunning(probe)
		return nil
	}

	// A rejected config kills sing-box in milliseconds. Catch that here so
	// /start answers with the core's own words rather than 200-then-silence.
	select {
	case waitErr := <-exited:
		rn.recordExitedLocked(describeExit(waitErr, tail.String()))
		return fmt.Errorf("sing-box exited immediately: %s", rn.lastErr)
	case <-time.After(rn.settleDelay()):
	case <-cancel:
		rn.stopLocked()
		rn.fail("start_cancelled: stopped while the tunnel was still coming up")
		return errors.New(rn.lastErr)
	case <-requestDone:
		rn.stopLocked()
		rn.fail("start_cancelled: HTTP request ended while the tunnel was still coming up")
		return errors.New(rn.lastErr)
	}
	// select may choose an elapsed settle timer even when cancellation is
	// already ready. A completed delay does not authorize an abandoned launch.
	if err := startCancellation(cancel, requestDone); err != nil {
		rn.stopLocked()
		rn.fail(err.Error())
		return errors.New(rn.lastErr)
	}
	rn.publishRunning(nil)
	return nil
}

// fail records why the tunnel is not up, in the one place /status reads and the
// one place the error strings are built from. Paired so the two can never drift
// — a lastErr without a matching snapshot is a red dot with no reason attached,
// which is the exact failure mode `detail` was added to end.
func (rn *Runner) fail(detail string) {
	// Naming the wreckage only when something actually went wrong: preflight
	// no longer refuses to start over an adapter left behind by an untracked
	// instance (see preflight.go), so when a start does fail afterwards, the
	// user needs to know it began from a dirty slate — that is the difference
	// between "retry" and "reboot".
	if rn.staleAdapter {
		detail += " [" + staleAdapterToken + "]"
	}
	rn.lastErr = detail
	rn.publish("error", detail)
}

// tailString is the child's last words, safe to call with or without rn.mu:
// rn.tail is an atomic.Pointer (see the field's doc comment) and tailBuffer
// guards its own bytes with its own mutex.
func (rn *Runner) tailString() string { return rn.tail.Load().String() }

// A reaped child still needs adapter/DNS cleanup if it died without servicing
// our graceful-stop signal. Publish failure immediately, then finish cleanup
// under mu so the next start cannot race the previous adapter's teardown.
// No receive on exited: the caller already consumed its only exit result.
func (rn *Runner) recordExitedLocked(detail string) {
	rn.cmd, rn.config, rn.exited = nil, nil, nil
	rn.disarmOwnerLocked()
	rn.fail(detail)
	rn.cleanupTunnel()
}

func (rn *Runner) stop() {
	rn.stopGeneration.Add(1)
	// Before taking mu, not after: a launch in progress holds mu for its whole
	// readiness wait, so a stop that started by asking for the lock would wait
	// out that budget before doing anything. The abort makes the launch give up
	// and release the lock; if nothing is starting this is a no-op.
	rn.abortStart()
	rn.mu.Lock()
	defer rn.mu.Unlock()
	rn.stopLocked()
	rn.lastErr = ""
	rn.publish("stopped", "")
}

// stopLocked kills the child and waits for it to actually be gone; the caller
// holds rn.mu. Returning before the process is reaped would let the next start
// race a still-live tunnel for the TUN device — and reaping the process is not
// even enough on its own: see the wait below.
func (rn *Runner) stopLocked() {
	rn.clearSession()
	cmd, exited := rn.cmd, rn.exited
	rn.cmd, rn.config, rn.exited = nil, nil, nil
	rn.disarmOwnerLocked()
	if cmd == nil || cmd.Process == nil {
		return
	}
	// Ask before shooting. sing-box removes the TUN device, the routes it
	// installed and its firewall state from the handler it runs on
	// SIGTERM/CTRL_BREAK; TerminateProcess runs none of that and leaves the OS
	// to notice on its own — which is where orphaned aurora0 adapters and a
	// resolver still full of tunnel-era answers come from. See graceful_*.go.
	reaped := false
	if exited != nil && signalGracefulStop(cmd) {
		select {
		case <-exited:
			reaped = true
		case <-time.After(gracefulStopBudget):
			// It was asked and did not go. Fall through to the kill; a stop
			// that waits forever on a wedged core is worse than an abrupt one.
		}
	}
	if !reaped {
		_ = cmd.Process.Kill()
		if exited != nil {
			select {
			case <-exited:
			case <-time.After(5 * time.Second):
			}
		}
	}
	rn.cleanupTunnel()
}

func (rn *Runner) cleanupTunnel() {
	// cmd.Wait() above only proves the process was reaped. On Windows the
	// wintun adapter is torn down after that, asynchronously — and the
	// watchdog's self-heal is exactly a stop→connect pair, so it races the
	// still-present adapter for the device on almost every self-heal. Wait
	// for the interface itself, not just the process that owned it.
	rn.tunnelGone()(auroraTunInterfaceName, tunnelTeardownBudget)
	// The one piece of teardown a killed core can never do for us. Harmless
	// after a graceful stop (sing-box already flushed), decisive after a kill:
	// without it the machine keeps answering DNS from addresses that were only
	// reachable through the tunnel it no longer has.
	flushResolverCache()
}

// pid reports the live child's PID (0 when stopped). Test seam.
func (rn *Runner) pid() int {
	rn.mu.Lock()
	defer rn.mu.Unlock()
	if rn.cmd == nil || rn.cmd.Process == nil {
		return 0
	}
	return rn.cmd.Process.Pid
}

// state answers /status without taking mu — see the snapshot field for why a
// lock here would freeze the app during a slow Windows launch. A runner that
// has never started anything has published nothing yet, which is "stopped".
func (rn *Runner) state() (string, string) {
	s := rn.snapshot.Load()
	if s == nil {
		return "stopped", ""
	}
	return s.state, s.detail
}

// describeExit turns a process error plus the captured output into one line the
// app can put in front of the user.
func describeExit(err error, tail string) string {
	parts := make([]string, 0, 2)
	if err != nil {
		parts = append(parts, err.Error())
	} else {
		parts = append(parts, "sing-box exited")
	}
	// Clipped, not dropped: the whole tail is in the log file and in /diagnose.
	// What reaches the user is the last thing the core said before it died,
	// which is the line that names the cause — everything above it is startup
	// chatter that pushed the answer off the top of the dialog.
	if tail = lastLines(tail, errorTailLines); tail != "" {
		parts = append(parts, tail)
	}
	return strings.Join(parts, ": ")
}

// writeRunConfig puts the config where the privileged side runs it from, with
// the directory locked to SYSTEM/Administrators so no unprivileged process can
// swap the file between our write and sing-box's read.
func writeRunConfig(path string, config []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	hardenPrivilegedDir(dir)
	return os.WriteFile(path, config, 0o600)
}

func openLogFile(path string) (*os.File, error) {
	if path == "" {
		return nil, errors.New("no log path")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	// Truncate per run: this is the "why did this connect fail" file, and the
	// answer is always in the newest run.
	return os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
}

type server struct {
	guard  *Guard
	runner *Runner
}

func (s *server) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/start", s.handleStart)
	mux.HandleFunc("/stop", s.handleStop)
	mux.HandleFunc("/status", s.handleStatus)
	mux.HandleFunc("/diagnose", s.handleDiagnose)
	return mux
}

func (s *server) handleStart(w http.ResponseWriter, r *http.Request) {
	if !s.guard.authorize(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	stopGeneration := s.runner.stopGeneration.Load()
	body, err := io.ReadAll(io.LimitReader(r.Body, maxConfigBytes+1))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	if len(body) > maxConfigBytes {
		http.Error(w, "config too large", http.StatusRequestEntityTooLarge)
		return
	}
	var req struct {
		Config string `json:"config"`
		// ClashProbe is optional: an older app build talking to a freshly
		// upgraded service won't send it, and that must still work — see
		// startWithProbe(config, nil).
		ClashProbe *clashProbe `json:"clash_probe"`
		// OwnerPid is optional and means "stop this tunnel if I die". The GUI
		// sends its own pid; `aurora-cli connect` deliberately does not, since
		// it exits on purpose and the tunnel must survive it. Absent (0) keeps
		// the pre-owner behaviour exactly, which is also what an older app
		// build talking to this service gets.
		OwnerPid int `json:"owner_pid"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	config := strings.TrimSpace(req.Config)
	if config == "" {
		http.Error(w, "missing config", http.StatusBadRequest)
		return
	}
	if !json.Valid([]byte(config)) {
		http.Error(w, "config is not valid json", http.StatusBadRequest)
		return
	}
	if err := s.runner.startOwnedGuarded(
		[]byte(config), req.ClashProbe, req.OwnerPid,
		func() bool {
			return r.Context().Err() == nil && s.runner.stopGeneration.Load() == stopGeneration
		},
		r.Context().Done(),
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *server) handleStop(w http.ResponseWriter, r *http.Request) {
	if !s.guard.authorize(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.runner.stop()
	w.WriteHeader(http.StatusOK)
}

func (s *server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if !s.guard.authorize(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	// An owner_pid on a status poll re-claims a tunnel this client did not
	// start — the app relaunching and adopting a session that outlived it. The
	// app polls once a second, so ownership is re-established within a second
	// of the new process existing, and never blocks (see Runner.claimOwner).
	if pid, err := strconv.Atoi(r.URL.Query().Get("owner_pid")); err == nil {
		s.runner.claimOwner(pid)
	}
	current := s.runner.statusSnapshot()
	// charset spelled out, not left to the reader's default: `detail` carries
	// sing-box's own words AND, on Windows, localized Win32 error strings — a
	// Chinese-locale machine puts non-ASCII on this wire routinely. Dart's http
	// package decodes a body with no charset as latin-1, which turns those into
	// mojibake in the one message whose whole job is to be readable.
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(struct {
		State  string      `json:"state"`
		Detail string      `json:"detail"`
		Probe  *clashProbe `json:"clash_probe,omitempty"`
	}{current.state, current.detail, current.probe})
}

// handleDiagnose answers "it says connected and nothing works" with facts.
//
// Reported 2026-08-14 on a machine nobody debugging it could reach: the tunnel
// came up, the app went green, and no traffic moved. Every existing surface
// could only repeat that sing-box was running — the Clash API answering is the
// readiness signal, and it proves the process started, not that the OS is
// routing anything through it. What is actually needed is the machine's own
// view: does aurora0 exist, what addresses does it carry, and what else on this
// box is claiming to be a network interface (a virtual switch from Hyper-V/WSL,
// a second VPN, a captive Ethernet). All of it is non-secret, so it can go into
// a screenshot or a support bundle as-is.
func (s *server) handleDiagnose(w http.ResponseWriter, r *http.Request) {
	if !s.guard.authorize(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	state, detail := s.runner.state()
	// charset for the same reason as /status, and it matters more here: Windows
	// adapter FriendlyNames ARE localized (for example "Ethernet" or "Local Area Connection" in the Windows UI language),
	// and this list is what the user picks a pinned egress NIC from. A mangled
	// name is a name sing-box will never resolve.
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(diagnosis{
		State:        state,
		Detail:       detail,
		OwnerPid:     int(s.runner.ownerPID.Load()),
		TunInterface: auroraTunInterfaceName,
		TunPresent:   s.runner.tunnelExists()(auroraTunInterfaceName),
		Interfaces:   collectInterfaces(),
		LogTail:      s.runner.tailString(),
	})
}

// listenLocal binds 127.0.0.1 on the fixed port for the app to reach.
func listenLocal(addr string) (net.Listener, error) {
	return net.Listen("tcp", addr)
}

func newServer() *server {
	p := resolvePaths(os.Getenv, exeDir())
	// Provision the shared credential before anyone can ask for it. The
	// privileged side owns it precisely because it is the side guaranteed to
	// have run first (the service auto-starts at boot). Failure is not fatal:
	// an existing token may still be readable, and a service that refuses to
	// start would be harder to diagnose than a 401.
	_, _ = ensureToken(p.TokenPath)
	return &server{
		guard: &Guard{TokenSource: fileToken(p.TokenPath)},
		runner: &Runner{
			SingBoxPath:   p.SingBox,
			WorkDir:       p.RunDir,
			ConfigPath:    p.ConfigPath,
			LogPath:       p.LogPath,
			RequiredFiles: requiredRuntimeFiles(p),
		},
	}
}
