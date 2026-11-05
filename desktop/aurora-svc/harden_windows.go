//go:build windows

package main

import (
	"os/exec"
	"path/filepath"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

const singBoxBinary = "sing-box.exe"

// wintun.dll must sit next to sing-box.exe or the TUN can never be created.
func requiredRuntimeFiles(p Paths) []string {
	return []string{filepath.Join(filepath.Dir(p.SingBox), "wintun.dll")}
}

// Directories the privileged side runs code/config out of: SYSTEM and the local
// Administrators group only. "D:P" drops the inheritance from %ProgramData%,
// which by default lets any standard user create files — without dropping it,
// an unprivileged process could swap the config we are about to hand a
// SYSTEM-level sing-box.
const privilegedDirSDDL = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"

// The shared bearer token must stay readable by the unelevated app, so local
// users get read — and only read.
const tokenFileSDDL = "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)"

func applyDACL(path, sddl string) {
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return
	}
	// Best effort: a box where we cannot set the DACL is still workable, and
	// failing the connect over it would be worse than the weaker ACL.
	_ = windows.SetNamedSecurityInfo(
		path,
		windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, dacl, nil,
	)
}

func hardenPrivilegedDir(path string) { applyDACL(path, privilegedDirSDDL) }

func hardenTokenFile(path string) { applyDACL(path, tokenFileSDDL) }

// One job object for the service's lifetime, with kill-on-close: when this
// process goes away for ANY reason (crash, SCM kill, uninstall), Windows
// terminates sing-box with it. Without this, a dead service leaves a live TUN
// interface owned by nobody — the machine keeps tunnelling while the app
// reports "Disconnected" and nothing short of a reboot fixes it.
var (
	jobOnce   sync.Once
	jobHandle windows.Handle
)

func childJob() windows.Handle {
	jobOnce.Do(func() {
		h, err := windows.CreateJobObject(nil, nil)
		if err != nil {
			return
		}
		info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
			BasicLimitInformation: windows.JOBOBJECT_BASIC_LIMIT_INFORMATION{
				LimitFlags: windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
			},
		}
		if _, err := windows.SetInformationJobObject(
			h,
			windows.JobObjectExtendedLimitInformation,
			uintptr(unsafe.Pointer(&info)),
			uint32(unsafe.Sizeof(info)),
		); err != nil {
			_ = windows.CloseHandle(h)
			return
		}
		jobHandle = h
	})
	return jobHandle
}

func superviseChild(cmd *exec.Cmd) {
	job := childJob()
	if job == 0 || cmd.Process == nil {
		return
	}
	h, err := windows.OpenProcess(
		windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE,
		false,
		uint32(cmd.Process.Pid),
	)
	if err != nil {
		return
	}
	defer windows.CloseHandle(h)
	_ = windows.AssignProcessToJobObject(job, h)
}

// prepareChild lives in graceful_windows.go on this platform: the only thing it
// has to do at spawn time is the process-group flag that makes a graceful stop
// addressable. Supervision proper is the job object above, applied after Start
// once cmd.Process exists.
