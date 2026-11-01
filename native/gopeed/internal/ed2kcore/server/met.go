// Package server holds the eD2k server side of the engine as a pure state
// machine: the server list, the one TCP server connection eMule keeps, and
// the UDP global source search across the other servers.
package server

import (
	"errors"
	"fmt"
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// Preference is a server.met priority. The numbering is eMule's
// (SRV_PR_NORMAL, SRV_PR_HIGH, SRV_PR_LOW), not an order; normal is the
// zero value.
type Preference uint32

const (
	PreferenceHigh Preference = 1
	PreferenceLow  Preference = 2
)

// Entry is one server of a server.met list. A server listed by Host has
// an Endpoint without an address until the name is resolved.
type Entry struct {
	Endpoint           netip.AddrPort
	Host               string
	Preference         Preference
	Failures           uint32
	Ping               uint32
	Users              uint32
	Files              uint32
	SoftFiles          uint32
	UDPFlags           uint32
	TCPObfuscationPort uint16
	UDPObfuscationPort uint16
	// PingedAt is when the server was last sent a status ping.
	PingedAt time.Time
	// UDPKey is the server's UDP obfuscation key for UDPKeyIP, our public
	// address when it came; the server derives it from that address
	// (aMule Server.cpp:307-321).
	UDPKey   uint32
	UDPKeyIP netip.Addr
}

// server.met tags (eMule Opcodes.h ST_*).
const (
	metPing               byte = 0x0C
	metFail               byte = 0x0D
	metPreference         byte = 0x0E
	metDynIP              byte = 0x85
	metSoftFiles          byte = 0x88
	metUDPFlags           byte = 0x92
	metTCPPortObfuscation byte = 0x97
	metUDPPortObfuscation byte = 0x98
)

var errMetVersion = errors.New("server: not a server.met file")

// ParseMet reads a server.met file. A server with a host name (ST_DYNIP) is
// always reached by that name, as aMule does (ServerSocket.cpp:598); its
// stored address is dropped. Other entries without a usable IPv4 endpoint
// are dropped.
func ParseMet(data []byte) ([]Entry, error) {
	r := &wire.Reader{Rest: data}
	switch r.Uint8() {
	// 0xE0 is the original eDonkey header, 0x0E MET_HEADER and 0x0F
	// MET_HEADER_I64TAGS are eMule's.
	case 0xE0, 0x0E, 0x0F:
	default:
		return nil, errMetVersion
	}
	count := r.Uint32()
	if uint64(count)*6 > uint64(r.Len()) {
		return nil, fmt.Errorf("server: server.met declares %d servers in %d bytes", count, r.Len())
	}
	var entries []Entry
	for range count {
		e := Entry{Endpoint: r.AddrPort()}
		for _, t := range r.Tags() {
			setMetTag(&e, t)
		}
		if r.Err() != nil {
			return nil, fmt.Errorf("server: server.met: %w", r.Err())
		}
		switch {
		case e.Host != "" && e.Endpoint.Port() != 0:
			e.Endpoint = netip.AddrPortFrom(netip.Addr{}, e.Endpoint.Port())
			entries = append(entries, e)
		case wire.IsDialable(e.Endpoint):
			entries = append(entries, e)
		}
	}
	return entries, nil
}

func setMetTag(e *Entry, t wire.Tag) {
	isUint := t.Type == wire.TagUint8 || t.Type == wire.TagUint16 || t.Type == wire.TagUint32
	switch {
	case t.Name == "users" && isUint:
		e.Users = uint32(t.Uint)
	case t.Name == "files" && isUint:
		e.Files = uint32(t.Uint)
	case t.Name != "":
	case t.ID == metDynIP && t.Type == wire.TagString && e.Host == "":
		e.Host = t.String
	case !isUint:
	case t.ID == metPing:
		e.Ping = uint32(t.Uint)
	case t.ID == metFail:
		e.Failures = uint32(t.Uint)
	case t.ID == metPreference:
		e.Preference = Preference(t.Uint)
	case t.ID == metSoftFiles:
		e.SoftFiles = uint32(t.Uint)
	case t.ID == metUDPFlags:
		e.UDPFlags = uint32(t.Uint)
	case t.ID == metTCPPortObfuscation:
		e.TCPObfuscationPort = uint16(t.Uint)
	case t.ID == metUDPPortObfuscation:
		e.UDPObfuscationPort = uint16(t.Uint)
	}
}
