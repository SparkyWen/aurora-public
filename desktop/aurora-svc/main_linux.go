//go:build linux

// Linux entrypoint: aurora-svc runs as a systemd service instead of a Windows
// SCM service. `install`/`uninstall` write and remove the unit; the bare
// invocation (what the unit's ExecStart runs) just serves the same HTTP API as
// every other platform — systemd owns the process lifecycle, so there is no
// SCM handshake to perform here.
package main

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
)

const (
	unitName = "aurora-svc.service"
	unitPath = "/etc/systemd/system/aurora-svc.service"
)

// unitTemplate is written by `aurora-svc install`. The .deb ships the same file;
// install exists so a manually-unpacked tarball (and a repair) works too.
const unitTemplate = `[Unit]
Description=Aurora VPN privileged helper
After=network.target

[Service]
Type=simple
ExecStart=%s run
Restart=on-failure
RestartSec=5
# The state dir must be machine-wide: this runs as root while the GUI runs as
# the logged-in user, so anything under a per-user directory would be two
# different places. Matches defaultStateBase().
StateDirectory=aurora
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=no

[Install]
WantedBy=multi-user.target
`

func installService() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if abs, err := filepath.Abs(exe); err == nil {
		exe = abs
	}
	unit := fmt.Sprintf(unitTemplate, exe)
	if err := os.WriteFile(unitPath, []byte(unit), 0o644); err != nil {
		return err
	}
	if err := run("systemctl", "daemon-reload"); err != nil {
		return err
	}
	// enable + restart in one step: an upgrade must land on the new binary, and
	// a service still pointing at a deleted path can never start again.
	if err := run("systemctl", "enable", unitName); err != nil {
		return err
	}
	return run("systemctl", "restart", unitName)
}

func uninstallService() error {
	paths := resolvePaths(os.Getenv, exeDir())
	_ = run("systemctl", "disable", "--now", unitName)
	// Symmetric with Windows (see service_windows.go): the shared token and the
	// last-run config live under StateDirectory=aurora, and systemd does not
	// remove a StateDirectory when a unit is disabled. Leaving them means an
	// uninstalled Aurora still has real credentials on disk.
	purgeMachineState(paths)
	if err := os.Remove(unitPath); err != nil && !os.IsNotExist(err) {
		return err
	}
	return run("systemctl", "daemon-reload")
}

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %v: %s", name, args, out)
	}
	return nil
}

func main() {
	// Defect 2, reproduced live 2026-08-03: this switch used to have no
	// default case, so an unrecognized verb (e.g. `--help`) fell straight
	// through to the foreground serve below and silently started listening on
	// svcListenAddr. parseVerb rejects anything that is not "install",
	// "uninstall", "run", or bare invocation BEFORE the switch runs.
	verb, ok := parseVerb(os.Args, "install", "uninstall")
	if !ok {
		fmt.Fprintf(os.Stderr, "%s: unrecognized argument %q\n", filepath.Base(os.Args[0]), verb)
		printUsage(filepath.Base(os.Args[0]), "install", "uninstall")
		os.Exit(2)
	}
	switch verb {
	case "install":
		if err := installService(); err != nil {
			fmt.Fprintln(os.Stderr, "install failed:", err)
			os.Exit(1)
		}
		return
	case "uninstall":
		if err := uninstallService(); err != nil {
			fmt.Fprintln(os.Stderr, "uninstall failed:", err)
			os.Exit(1)
		}
		return
	}
	// `run` and the bare invocation are the same thing here: systemd owns the
	// lifecycle, so there is no SCM handshake to perform.
	ln, err := listenLocal(svcListenAddr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen failed:", err)
		os.Exit(1)
	}
	_ = http.Serve(ln, newServer().routes())
}
