//go:build windows

package main

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const (
	serviceName = "AuroraSvc"
	displayName = "Aurora VPN Service"
	description = "Runs sing-box with TUN privileges for the Aurora VPN app."
)

type auroraService struct{ srv *server }

func (a *auroraService) Execute(_ []string, r <-chan svc.ChangeRequest, s chan<- svc.Status) (bool, uint32) {
	s <- svc.Status{State: svc.StartPending}
	ln, err := listenLocal(svcListenAddr)
	if err != nil {
		// A service that dies with a bare exit code is undiagnosable from the
		// app side; leave the reason somewhere a human can read it.
		svcLogf("listen %s failed: %v", svcListenAddr, err)
		return true, 1
	}
	svcLogf("listening on %s", svcListenAddr)
	httpSrv := &http.Server{Handler: a.srv.routes()}
	go httpSrv.Serve(ln)
	s <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for c := range r {
		switch c.Cmd {
		case svc.Interrogate:
			s <- c.CurrentStatus
		case svc.Stop, svc.Shutdown:
			// Stop-Service waits for StopPending while cleanup is in progress.
			// The owner's cleanup can still hold runner.mu after the child exits.
			// Report progress before waiting for that lock or tearing anything down.
			s <- svc.Status{State: svc.StopPending}
			svcLogf("stopping")
			a.srv.runner.stop()
			_ = httpSrv.Close()
			return false, 0
		default:
		}
	}
	return false, 0
}

// svcLogf appends one line to %ProgramData%\Aurora\logs\aurora-svc.log. Best
// effort — diagnostics must never be able to take the service down.
func svcLogf(format string, args ...any) {
	p := resolvePaths(os.Getenv, exeDir())
	path := filepath.Join(filepath.Dir(p.LogPath), "aurora-svc.log")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
}

// installService registers (or repairs) the service and leaves it running.
//
// It must RECONCILE, not bail out when a registration already exists: the old
// portable build registered the service from wherever the user unzipped it, and
// an upgrade installs to a different directory. A service still pointing at a
// deleted folder can never start again, and the app would just keep reporting
// that the helper is unreachable.
func installService() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if abs, err := filepath.Abs(exe); err == nil {
		exe = abs
	}
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()

	if s, err := m.OpenService(serviceName); err == nil {
		defer s.Close()
		cfg, err := s.Config()
		if err != nil {
			return err
		}
		cfg.BinaryPathName = windows.EscapeArg(exe) + " run"
		cfg.StartType = mgr.StartAutomatic
		cfg.DisplayName = displayName
		cfg.Description = description
		if err := s.UpdateConfig(cfg); err != nil {
			return err
		}
		setRecoveryActions(s)
		return restartService(s)
	}

	s, err := m.CreateService(serviceName, exe, mgr.Config{
		StartType:   mgr.StartAutomatic,
		DisplayName: displayName,
		Description: description,
	}, "run")
	if err != nil {
		return err
	}
	defer s.Close()
	setRecoveryActions(s)
	return startService(s)
}

// setRecoveryActions asks the SCM to bring the helper back if it ever dies.
// Best effort: an install that fails over a recovery policy would be worse
// than an install without one.
func setRecoveryActions(s *mgr.Service) {
	_ = s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 15 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}, 86400)
}

func startService(s *mgr.Service) error {
	if err := s.Start(); err != nil {
		if errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
			return nil
		}
		return err
	}
	return nil
}

// restartService stops and starts, waiting for the stop to actually complete —
// starting a service that is still StopPending fails.
func restartService(s *mgr.Service) error {
	if st, err := s.Query(); err == nil && st.State != svc.Stopped {
		if _, err := s.Control(svc.Stop); err == nil {
			waitForState(s, svc.Stopped, 20*time.Second)
		}
	}
	return startService(s)
}

func waitForState(s *mgr.Service, want svc.State, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		st, err := s.Query()
		if err != nil || st.State == want {
			return
		}
		time.Sleep(300 * time.Millisecond)
	}
}

// uninstallService removes the registration AND everything the service left on
// the machine — see purgeMachineState for what "uninstall leaves things behind" actually consisted
// of.
//
// The two deletion hazards this handles are both silent by default. A service
// with an open handle anywhere (services.msc left open on the row, a monitoring
// agent enumerating services) is only MARKED for deletion by DeleteService and
// stays in the list until the last handle closes; and DeleteService on a
// service that has not finished stopping fails outright. So: wait for STOPPED,
// then retry the delete, then verify it is actually gone and say so if it is
// not — a reboot finishes a pending delete, and the user deserves to be told
// that rather than discovering "Aurora VPN Service" still listed next week.
func uninstallService() error {
	paths := resolvePaths(os.Getenv, exeDir())
	err := deleteService()
	// State goes regardless of whether the registration could be removed: a
	// half-removed service that can no longer start must not keep the token and
	// the credential-bearing config alive on disk.
	purgeMachineState(paths)
	return err
}

func deleteService() error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return nil // not installed — uninstalling is already the desired state
	}
	if _, err := s.Control(svc.Stop); err == nil {
		// Let the stop handler tear the tunnel down before the binary
		// disappears; otherwise the uninstaller races a live tunnel.
		waitForState(s, svc.Stopped, 20*time.Second)
	}
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		if lastErr = s.Delete(); lastErr == nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	// Closing our own handle is what lets a marked-for-deletion service
	// actually go, so the existence check below has to come after it.
	_ = s.Close()
	if again, err := m.OpenService(serviceName); err == nil {
		_ = again.Close()
		return fmt.Errorf(
			"service %s is marked for deletion but still registered "+
				"(something else has it open); it disappears at the next reboot",
			serviceName,
		)
	}
	return lastErr
}

func main() {
	// Defect 2, reproduced live 2026-08-03 (on Linux, but this switch has the
	// identical shape): with no default case, an unrecognized verb fell
	// through every explicit case and reached the foreground fallback below,
	// silently starting a privileged listener on svcListenAddr instead of
	// reporting usage. parseVerb rejects anything that is not "install",
	// "uninstall", "run", or bare invocation before the switch runs at all.
	// The "run" case itself is UNCHANGED: it must keep doing the SCM handshake
	// via svc.Run, not the foreground http.Serve — that distinction is
	// load-bearing (the SCM kills the service if it does not see the expected
	// status transitions promptly).
	verb, ok := parseVerb(os.Args, "install", "uninstall")
	if !ok {
		fmt.Fprintf(os.Stderr, "%s: unrecognized argument %q\n", filepath.Base(os.Args[0]), verb)
		printUsage(filepath.Base(os.Args[0]), "install", "uninstall")
		os.Exit(2)
	}
	switch verb {
	case "install":
		if err := installService(); err != nil {
			svcLogf("install failed: %v", err)
			fmt.Fprintln(os.Stderr, "install failed:", err)
			os.Exit(1)
		}
		svcLogf("installed from %s", exeDir())
		return
	case "uninstall":
		if err := uninstallService(); err != nil {
			svcLogf("uninstall failed: %v", err)
			fmt.Fprintln(os.Stderr, "uninstall failed:", err)
			os.Exit(1)
		}
		svcLogf("uninstalled")
		return
	case "run":
		_ = svc.Run(serviceName, &auroraService{srv: newServer()})
		return
	}
	// Foreground fallback (manual debugging) — bare invocation only. "run" is
	// handled above via the SCM handshake, and an unrecognized verb already
	// exited above instead of ever reaching here.
	ln, err := listenLocal(svcListenAddr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen failed:", err)
		os.Exit(1)
	}
	_ = http.Serve(ln, newServer().routes())
}
