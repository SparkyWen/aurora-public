package main

// ansi.go strips ANSI/VT100 terminal escape sequences from text that is about
// to become an API response field, not a terminal.
//
// Defect 1, reproduced live on 2026-08-03: POSTing a config with an unknown
// outbound type produced this /status body:
//
//	{"detail":"config rejected by sing-box: \x1b[31mFATAL\x1b[0m[0000] decode
//	config at /var/lib/aurora/run/config.json: outbounds[0]: unknown outbound
//	type: nonexistent_proto","state":"error"}
//
// sing-box colourises its logrus-style output (SGR codes via CSI — the
// "\x1b[31m"/"\x1b[0m" above) on the assumption that stdout/stderr is a
// terminal. The Flutter app now shows /status's "detail" verbatim in an error
// dialog (ConnectFlow.describeError); there is no terminal there, so those
// raw escape bytes would render as literal junk around the one sentence the
// user actually needs to read.

const esc = 0x1b

// stripANSI removes ANSI/VT100 escape sequences from b, returning a new slice
// with every other byte preserved in order.
//
// Recognised forms:
//   - CSI (ESC '[' params intermediates final) — required by the task, and
//     what the exact repro above actually is: both "\x1b[31m" and "\x1b[0m"
//     are CSI/SGR sequences ending in the final byte 'm'.
//   - OSC (ESC ']' ... terminated by BEL or ESC '\') — not observed from
//     sing-box (its colourisation is plain CSI/SGR, per the repro), but this
//     function exists to sanitise "whatever a binary this package
//     deliberately does not fork happens to print" (see the no-fork hard
//     constraint in CONTRIBUTING.md), not just the one sequence caught so far. OSC 8 hyperlinks are a
//     realistic thing some logging/colour libraries emit, and recognising
//     them costs nothing extra at call time.
//   - Any other ESC followed by a single byte is dropped as those two bytes.
//     A sequence form this function does not specifically parse must still
//     not leave a raw ESC (0x1b) byte sitting in JSON shown in a dialog —
//     that would be exactly as much garbage as a full CSI sequence.
//   - A malformed/truncated escape (cut off by e.g. tailBuffer's max-length
//     trim, or a short pipe read) is dropped rather than echoed partially:
//     "[31" left dangling in the output would read as noise, not a message.
func stripANSI(b []byte) []byte {
	out := make([]byte, 0, len(b))
	i := 0
	for i < len(b) {
		if b[i] != esc {
			out = append(out, b[i])
			i++
			continue
		}
		// b[i] is ESC. Nothing after it: drop the lone byte and stop.
		if i+1 >= len(b) {
			break
		}
		switch b[i+1] {
		case '[': // CSI: ESC '[' params(0x30-0x3F)* intermediates(0x20-0x2F)* final(0x40-0x7E)
			j := i + 2
			for j < len(b) && b[j] >= 0x30 && b[j] <= 0x3f {
				j++
			}
			for j < len(b) && b[j] >= 0x20 && b[j] <= 0x2f {
				j++
			}
			if j < len(b) && b[j] >= 0x40 && b[j] <= 0x7e {
				j++ // consume the final byte too
			}
			i = j
		case ']': // OSC: ESC ']' ... terminated by BEL (0x07) or ST (ESC '\')
			j := i + 2
			for j < len(b) {
				if b[j] == 0x07 {
					j++
					break
				}
				if b[j] == esc && j+1 < len(b) && b[j+1] == '\\' {
					j += 2
					break
				}
				j++
			}
			i = j
		default: // bare two-byte escape: drop ESC and the byte after it
			i += 2
		}
	}
	return out
}
