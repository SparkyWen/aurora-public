//go:build !windows && !linux

// Neither-Windows-nor-Linux stubs (macOS dev boxes today). The service only
// runs for real on Windows and Linux; this keeps the package buildable and
// testable on macOS.
package main

import "os/exec"

const singBoxBinary = "sing-box"

// No extra runtime files on this platform.
func requiredRuntimeFiles(Paths) []string { return nil }

func hardenPrivilegedDir(string) {}

func hardenTokenFile(string) {}

func superviseChild(*exec.Cmd) {}

func prepareChild(*exec.Cmd) {}
