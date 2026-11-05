package main

import "testing"

// Defect 1, reproduced live on 2026-08-03: POSTing a config with an unknown
// outbound type produced this literal /status body —
//
//	{"detail":"config rejected by sing-box: \x1b[31mFATAL\x1b[0m[0000] decode
//	config at /var/lib/aurora/run/config.json: outbounds[0]: unknown outbound
//	type: nonexistent_proto","state":"error"}
//
// sing-box colourises its logrus-style output assuming a terminal on the
// other end; the Flutter app now shows `detail` verbatim in an error dialog
// (ConnectFlow.describeError), where there is no terminal. This test pins the
// exact bytes sing-box emitted and asserts they come out clean.
func TestStripANSIRemovesTheExactSequenceSingBoxEmitted(t *testing.T) {
	in := "\x1b[31mFATAL\x1b[0m[0000] decode config at /var/lib/aurora/run/config.json: outbounds[0]: unknown outbound type: nonexistent_proto"
	want := "FATAL[0000] decode config at /var/lib/aurora/run/config.json: outbounds[0]: unknown outbound type: nonexistent_proto"
	if got := string(stripANSI([]byte(in))); got != want {
		t.Fatalf("stripANSI(%q) = %q, want %q", in, got, want)
	}
}

func TestStripANSILeavesPlainTextAlone(t *testing.T) {
	in := "plain error with no escapes at all"
	if got := string(stripANSI([]byte(in))); got != in {
		t.Fatalf("stripANSI must not touch text with no escapes, got %q", got)
	}
}

func TestStripANSIHandlesMultipleCodesInOneLine(t *testing.T) {
	in := "\x1b[1;31mbold red\x1b[0m and \x1b[32mgreen\x1b[0m"
	want := "bold red and green"
	if got := string(stripANSI([]byte(in))); got != want {
		t.Fatalf("stripANSI(%q) = %q, want %q", in, got, want)
	}
}

// OSC sequences have not been observed from sing-box (its colourisation is
// plain CSI/SGR, as the exact repro above shows), but this stripper is meant
// to sanitise "whatever a binary we deliberately do not fork happens to
// print" — not just the one sequence caught so far. OSC 8 hyperlinks are a
// realistic thing a future logging library could emit, and covering them
// costs nothing extra at call time, so stripANSI recognises them too.
func TestStripANSIHandlesOSCSequences(t *testing.T) {
	in := "before \x1b]8;;http://example.com\x1b\\linktext\x1b]8;;\x1b\\ after"
	want := "before linktext after"
	if got := string(stripANSI([]byte(in))); got != want {
		t.Fatalf("stripANSI(%q) = %q, want %q", in, got, want)
	}
}

func TestStripANSIDropsATrailingLoneEscape(t *testing.T) {
	in := "truncated\x1b"
	want := "truncated"
	if got := string(stripANSI([]byte(in))); got != want {
		t.Fatalf("stripANSI(%q) = %q, want %q", in, got, want)
	}
}

// A CSI sequence split by a buffer boundary (e.g. tailBuffer's max-length
// truncation, or a short read from the child's pipe) must not leave a raw
// ESC or partial parameter bytes behind — better to drop the fragment than
// show "[31" as if it were meaningful text.
func TestStripANSIDropsATruncatedCSISequence(t *testing.T) {
	in := "before\x1b[31"
	want := "before"
	if got := string(stripANSI([]byte(in))); got != want {
		t.Fatalf("stripANSI(%q) = %q, want %q", in, got, want)
	}
}

func TestStripANSIDropsABareTwoByteEscape(t *testing.T) {
	// ESC 'M' (reverse index) is not CSI or OSC, just ESC + one byte. Any
	// sequence form this function does not specifically parse must still not
	// leave a raw ESC (0x1b) byte in API-facing text.
	in := "a\x1bMb"
	want := "ab"
	if got := string(stripANSI([]byte(in))); got != want {
		t.Fatalf("stripANSI(%q) = %q, want %q", in, got, want)
	}
}
