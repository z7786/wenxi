package wire

import (
	"encoding/binary"
	"net/netip"
)

// lowIDLimit is the first HighID. A HighID is the client's IPv4 address read
// as a little-endian uint32, so every address whose first byte is non-zero
// lands at or above it; anything below is a server-assigned LowID.
const lowIDLimit = 16777216

// IPv6Sentinel is the client id that marks a source carrying an IPv6
// address (emule-qt ipv6-spec §1.4, §4.4).
const IPv6Sentinel = 0xFFFFFFFF

func IsLowID(id uint32) bool { return id < lowIDLimit }

// ToClientID returns the HighID of an IPv4 address; other addresses give 0.
func ToClientID(addr netip.Addr) uint32 {
	if !addr.Is4() {
		return 0
	}
	a := addr.As4()
	return binary.LittleEndian.Uint32(a[:])
}

// ToAddr returns the IPv4 address a HighID stands for.
func ToAddr(id uint32) netip.Addr {
	var a [4]byte
	binary.LittleEndian.PutUint32(a[:], id)
	return netip.AddrFrom4(a)
}

// IsPublic follows aMule's IsGoodIP with FilterLanIPs on
// (NetworkFunctions.cpp:99-151): no "this network" 0/8, loopback, link-local,
// multicast, 240/4 (which holds 255.255.255.255) or private LAN address.
// aMule's other reserved ranges are left out: several, like 39/8, have since
// been allocated.
func IsPublic(addr netip.Addr) bool {
	addr = addr.Unmap()
	if addr.Is4() && (addr.As4()[0] == 0 || addr.As4()[0] >= 240) {
		return false
	}
	return addr.IsGlobalUnicast() && !addr.IsPrivate()
}

// IsDialable reports whether an IPv4 endpoint can be reached at all: it has
// a port and its address is not unspecified, multicast or broadcast. LAN and
// loopback addresses pass.
func IsDialable(endpoint netip.AddrPort) bool {
	addr := endpoint.Addr()
	return addr.Is4() && endpoint.Port() != 0 && !addr.IsUnspecified() && !addr.IsMulticast() &&
		addr != netip.AddrFrom4([4]byte{255, 255, 255, 255})
}
