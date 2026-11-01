package nat

import (
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"syscall"
	"unsafe"
)

var getBestRoute2 = syscall.NewLazyDLL("iphlpapi.dll").NewProc("GetBestRoute2")

// ipForwardRow2 mirrors MIB_IPFORWARD_ROW2 (104 bytes); only the interface
// index and NextHop (a SOCKADDR_INET at offset 44) are read.
type ipForwardRow2 struct {
	luid        uint64
	index       uint32
	destination [32]byte
	nextHop     [28]byte
	rest        [32]byte
}

// probeGateway asks GetBestRoute2 for the route to a documentation address:
// the IP Helper API is locale-independent, unlike `route print`, and covers
// both families with one call.
func probeGateway(ctx context.Context, isIPv6 bool) (netip.Addr, error) {
	var destination [28]byte
	if isIPv6 {
		binary.LittleEndian.PutUint16(destination[0:], syscall.AF_INET6)
		ip := netip.MustParseAddr("2001:db8::1").As16()
		copy(destination[8:24], ip[:])
	} else {
		binary.LittleEndian.PutUint16(destination[0:], syscall.AF_INET)
		copy(destination[4:8], []byte{192, 0, 2, 1})
	}
	var row ipForwardRow2
	var source [28]byte
	status, _, _ := getBestRoute2.Call(0, 0, 0, uintptr(unsafe.Pointer(&destination)), 0, uintptr(unsafe.Pointer(&row)), uintptr(unsafe.Pointer(&source)))
	if status != 0 {
		return netip.Addr{}, fmt.Errorf("nat: GetBestRoute2: %w", syscall.Errno(status))
	}

	var ip netip.Addr
	switch binary.LittleEndian.Uint16(row.nextHop[0:]) {
	case syscall.AF_INET:
		ip = netip.AddrFrom4([4]byte(row.nextHop[4:8]))
	case syscall.AF_INET6:
		ip = netip.AddrFrom16([16]byte(row.nextHop[8:24]))
	}
	if !ip.IsValid() || ip.IsUnspecified() {
		return netip.Addr{}, fmt.Errorf("nat: no default gateway")
	}
	if ip.IsLinkLocalUnicast() && ip.Is6() {
		zone := strconv.Itoa(int(row.index))
		if intf, err := net.InterfaceByIndex(int(row.index)); err == nil {
			zone = intf.Name
		}
		ip = ip.WithZone(zone)
	}
	return ip, nil
}
