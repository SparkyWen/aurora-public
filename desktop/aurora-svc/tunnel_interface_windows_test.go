package main

import (
	"errors"
	"runtime"
	"testing"

	"golang.org/x/sys/windows"
)

// API-boundary fixture, not a simulated PnP deletion. The real Windows trace
// captured 72 consecutive ordinary-absent/ALL-present samples after core exit.
// Ordinary GAA omits this unbound Down interface; only ALL returns its row.
func TestWindowsTunnelFindsUnboundDownInterface(t *testing.T) {
	name, err := windows.UTF16FromString("AuRoRa0")
	if err != nil {
		t.Fatal(err)
	}
	query := func(family, flags uint32, reserved uintptr, out *windows.IpAdapterAddresses, size *uint32) error {
		if family != windows.AF_UNSPEC || reserved != 0 {
			t.Fatal("unexpected enumeration scope")
		}
		if flags&windows.GAA_FLAG_INCLUDE_ALL_INTERFACES == 0 {
			*size = 0
			return nil
		}
		out.FriendlyName = &name[0]
		out.OperStatus = windows.IfOperStatusDown
		return nil
	}
	found, err := windowsTunnelInterfaceExists(auroraTunInterfaceName, query)
	if err != nil || !found {
		t.Fatalf("unbound Down interface reported gone: present=%v err=%v", found, err)
	}
	runtime.KeepAlive(name)
}

func TestWindowsTunnelWalksInterfaceList(t *testing.T) {
	names := make([][]uint16, 2)
	names[0], _ = windows.UTF16FromString("unrelated0")
	names[1], _ = windows.UTF16FromString(auroraTunInterfaceName)
	second := windows.IpAdapterAddresses{FriendlyName: &names[1][0], OperStatus: windows.IfOperStatusDown}
	query := func(_ uint32, _ uint32, _ uintptr, out *windows.IpAdapterAddresses, _ *uint32) error {
		out.FriendlyName = &names[0][0]
		out.Next = &second
		return nil
	}
	for _, tc := range []struct {
		name string
		want bool
	}{{auroraTunInterfaceName, true}, {"absent0", false}} {
		found, err := windowsTunnelInterfaceExists(tc.name, query)
		if err != nil || found != tc.want {
			t.Fatalf("lookup %q: present=%v err=%v", tc.name, found, err)
		}
	}
	runtime.KeepAlive(names)
	runtime.KeepAlive(second)
}

func TestWindowsTunnelRetriesGrowingBuffer(t *testing.T) {
	name, _ := windows.UTF16FromString(auroraTunInterfaceName)
	calls := 0
	query := func(_ uint32, _ uint32, _ uintptr, out *windows.IpAdapterAddresses, size *uint32) error {
		calls++
		if calls == 1 {
			*size = 30000
			return windows.ERROR_BUFFER_OVERFLOW
		}
		if *size < 30000 {
			t.Fatal("retry did not grow the buffer")
		}
		out.FriendlyName = &name[0]
		return nil
	}
	found, err := windowsTunnelInterfaceExists(auroraTunInterfaceName, query)
	if err != nil || !found || calls != 2 {
		t.Fatalf("retry: present=%v calls=%d err=%v", found, calls, err)
	}
	runtime.KeepAlive(name)
}

func TestWindowsTunnelBoundsBufferRetries(t *testing.T) {
	for _, mode := range []string{"unchanged", "keeps_growing", "oversized"} {
		t.Run(mode, func(t *testing.T) {
			calls := 0
			query := func(_ uint32, _ uint32, _ uintptr, _ *windows.IpAdapterAddresses, size *uint32) error {
				calls++
				if mode == "keeps_growing" {
					*size *= 2
				}
				if mode == "oversized" {
					*size = 8 << 20
				}
				return windows.ERROR_BUFFER_OVERFLOW
			}
			found, err := windowsTunnelInterfaceExists(auroraTunInterfaceName, query)
			if found || err == nil || calls > 4 {
				t.Fatalf("unbounded/accepted growth: present=%v calls=%d err=%v", found, calls, err)
			}
		})
	}
}

func TestWindowsTunnelEmptyAndFailedEnumeration(t *testing.T) {
	for _, enumerationErr := range []error{nil, windows.ERROR_ACCESS_DENIED} {
		query := func(_ uint32, _ uint32, _ uintptr, _ *windows.IpAdapterAddresses, size *uint32) error {
			*size = 0
			return enumerationErr
		}
		found, err := windowsTunnelInterfaceExists(auroraTunInterfaceName, query)
		if found || !errors.Is(err, enumerationErr) {
			t.Fatalf("empty/failed query: present=%v err=%v", found, err)
		}
	}
}
