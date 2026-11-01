package kad

import (
	"fmt"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
)

// Node is one Kad contact: its ID, UDP endpoint, TCP port and Kad version.
type Node struct {
	ID      wire.Hash
	Addr    netip.AddrPort
	TCPPort uint16
	Version byte
}

// ParseNodes reads an eMule nodes.dat. Version 0 files start with the
// contact count; later versions start with a zero count, the version, and
// for version 3 a bootstrap edition. Version 2 and 3 non-bootstrap entries
// carry an 8-byte UDP key and a verified flag after the 25-byte contact.
// Contacts with unusable addresses are skipped.
func ParseNodes(data []byte) ([]Node, error) {
	r := &wire.Reader{Rest: data}
	count := r.Uint32()
	version := uint32(0)
	hasKeys := false
	if count == 0 {
		version = r.Uint32()
		switch version {
		case 1:
		case 2:
			hasKeys = true
		case 3:
			hasKeys = r.Uint32() != 1
		default:
			return nil, fmt.Errorf("kad: unsupported nodes.dat version %d", version)
		}
		count = r.Uint32()
	}
	entrySize := 25
	if hasKeys {
		entrySize += 9
	}
	if r.Err() != nil || count == 0 || uint64(count)*uint64(entrySize) > uint64(r.Len()) {
		return nil, fmt.Errorf("kad: not a nodes.dat")
	}
	nodes := make([]Node, 0, count)
	for range count {
		id := kadwire.ParseID(r)
		addr := netip.AddrPortFrom(kadwire.ToAddr(r.Uint32()), r.Uint16())
		node := Node{ID: id, Addr: addr, TCPPort: r.Uint16()}
		// Version 0 files store a contact type where later ones store the
		// Kad version; eMule drops types 4 and up as dead.
		if version == 0 {
			if r.Uint8() >= 4 {
				continue
			}
		} else {
			node.Version = r.Uint8()
		}
		if hasKeys {
			r.Bytes(9)
		}
		if matchGoodAddr(node.Addr) {
			nodes = append(nodes, node)
		}
	}
	return nodes, r.Err()
}

func toNode(ct kadwire.Contact) Node {
	return Node{ID: ct.ID, Addr: netip.AddrPortFrom(ct.Addr, ct.UDPPort), TCPPort: ct.TCPPort, Version: ct.Version}
}

func toStoreNode(n Node) store.KadNode {
	return store.KadNode{ID: n.ID, Addr: n.Addr, TCPPort: n.TCPPort, Version: n.Version}
}

// matchGoodNode rejects Kad 1 nodes, which do not read Kad 2 requests, and
// nodes before Kad 6 on port 53, which cannot obfuscate against DNS protocol
// confusion (RoutingZone.cpp:183-189).
func matchGoodNode(n Node) bool {
	return n.Version > 1 && !(n.Addr.Port() == 53 && n.Version <= 5) && matchGoodAddr(n.Addr)
}

// matchGoodAddr rejects endpoints no Kad node can listen on.
func matchGoodAddr(addr netip.AddrPort) bool {
	return wire.IsDialable(addr) && !addr.Addr().IsLoopback()
}
