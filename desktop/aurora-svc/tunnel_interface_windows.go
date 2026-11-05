package main

import (
	"fmt"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

type adapterAddressesCall func(uint32, uint32, uintptr, *windows.IpAdapterAddresses, *uint32) error

func tunnelInterfaceExists(name string) bool {
	found, _ := windowsTunnelInterfaceExists(name, windows.GetAdaptersAddresses)
	return found // Preserve the existing false-on-enumeration-error behavior.
}

// The IP interface table is not a PnP removal barrier. Even the ALL query may
// miss a device being created/removed, so readiness still verifies the new
// child. This function only supplies the existing bounded teardown/preflight
// waits with the OS's current interface presence, without filtering Down.
func windowsTunnelInterfaceExists(name string, query adapterAddressesCall) (bool, error) {
	// net.Interfaces omits INCLUDE_ALL_INTERFACES. After an owned core exits,
	// Windows can remove its IP binding while the named NDIS interface is still
	// present and Down. Ordinary GAA then reports it gone too early, skipping
	// the existing teardown wait. Include that row until Windows removes it.
	const flags = windows.GAA_FLAG_INCLUDE_PREFIX | windows.GAA_FLAG_INCLUDE_GATEWAYS |
		windows.GAA_FLAG_INCLUDE_ALL_INTERFACES
	const maxBuffer = 4 << 20
	size := uint32(15000) // GetAdaptersAddresses' recommended initial allocation.
	for attempt := 0; attempt < 4; attempt++ {
		if size == 0 || size > maxBuffer {
			return false, fmt.Errorf("GetAdaptersAddresses: invalid buffer size")
		}
		buffer := make([]byte, size)
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buffer[0]))
		err := query(windows.AF_UNSPEC, flags, 0, first, &size)
		if err == windows.ERROR_BUFFER_OVERFLOW && size > uint32(len(buffer)) {
			continue
		}
		if err != nil {
			return false, fmt.Errorf("GetAdaptersAddresses: %w", err)
		}
		if size == 0 {
			return false, nil
		}
		found := false
		for adapter := first; adapter != nil; adapter = adapter.Next {
			if strings.EqualFold(windows.UTF16PtrToString(adapter.FriendlyName), name) {
				found = true
				break
			}
		}
		runtime.KeepAlive(buffer)
		return found, nil
	}
	return false, fmt.Errorf("GetAdaptersAddresses: buffer kept growing")
}
