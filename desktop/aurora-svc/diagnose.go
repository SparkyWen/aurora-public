package main

import (
	"net"
	"sort"
)

// diagnosis is one /diagnose answer: everything the privileged side can say
// about why a tunnel that reports "connected" might not be carrying traffic.
//
// Nothing here is a secret. The config, the credentials it contains and the
// bearer token are all deliberately absent — this is written to be pasted into
// a screenshot by a user who is not going to redact anything.
type diagnosis struct {
	State  string `json:"state"`
	Detail string `json:"detail"`
	// OwnerPid is the process this tunnel belongs to, 0 when nobody claimed it
	// (a CLI-started tunnel, or a start from an app build that predates
	// ownership). Worth reporting: "the tunnel is up and its owner is a pid
	// that no longer exists" and "the tunnel is up and unowned on purpose" look
	// identical from outside.
	OwnerPid     int               `json:"owner_pid"`
	TunInterface string            `json:"tun_interface"`
	TunPresent   bool              `json:"tun_present"`
	Interfaces   []interfaceReport `json:"interfaces"`
	// LogTail is the core's own output, whole — unlike the clipped copy an
	// error carries (see errorTailLines).
	LogTail string `json:"log_tail"`
}

// interfaceReport is one row of the machine's interface table.
type interfaceReport struct {
	Name      string   `json:"name"`
	Index     int      `json:"index"`
	Up        bool     `json:"up"`
	MTU       int      `json:"mtu"`
	Addresses []string `json:"addresses"`
}

// collectInterfaces reads the OS interface table.
//
// The interesting question it answers is rarely about aurora0 itself: it is
// what ELSE is on the box. sing-box binds its own outbound to whatever Windows
// calls the default interface (route.auto_detect_interface), so a Hyper-V or
// WSL virtual switch, a second VPN's adapter, or an Ethernet link that is up
// but going nowhere all change which way the tunnel's own packets leave —
// and none of that is visible from inside the app.
func collectInterfaces() []interfaceReport {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	reports := make([]interfaceReport, 0, len(ifaces))
	for _, ifi := range ifaces {
		report := interfaceReport{
			Name:  ifi.Name,
			Index: ifi.Index,
			Up:    ifi.Flags&net.FlagUp != 0,
			MTU:   ifi.MTU,
		}
		if addrs, err := ifi.Addrs(); err == nil {
			for _, addr := range addrs {
				report.Addresses = append(report.Addresses, addr.String())
			}
		}
		reports = append(reports, report)
	}
	// Stable order so two captures from the same machine can be diffed by eye;
	// net.Interfaces() makes no ordering promise.
	sort.Slice(reports, func(i, j int) bool {
		return reports[i].Index < reports[j].Index
	})
	return reports
}
