//go:build !windows

package main

import (
	"net"
	"strings"
)

func tunnelInterfaceExists(name string) bool {
	ifaces, err := net.Interfaces()
	if err != nil {
		return false
	}
	for _, ifi := range ifaces {
		if strings.EqualFold(ifi.Name, name) {
			return true
		}
	}
	return false
}
