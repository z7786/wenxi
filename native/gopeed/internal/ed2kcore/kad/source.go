package kad

import (
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
)

// File is one file the engine downloads or shares. Kad searches sources
// for an incomplete file until it has enough, and publishes us as a source
// of a shared one.
type File struct {
	Hash wire.Hash
	Size int64
	// Sources is how many usable sources the file has.
	Sources    int
	IsComplete bool
	IsShared   bool
}

// Wanted is every file the engine downloads or shares. Each one posted
// replaces the previous set, so a dropped update is repaired by the next
// one (ADR-0005).
type Wanted []File

// Source types, as eMule's CSearch::StorePacket publishes them.
const (
	sourceOpen            byte = 1 // HighID
	sourceFirewalled      byte = 3 // reachable only through its buddy
	sourceOpenLarge       byte = 4 // HighID, file over 4 GB
	sourceFirewalledLarge byte = 5 // firewalled, file over 4 GB
	SourceDirectCallback  byte = 6 // firewalled, but takes callback requests over UDP itself
)

// Source is one peer that has a file, as Kad reported it. For firewalled
// types the engine cannot connect to Addr; it asks Kad to RequestCallback
// through Buddy, or for SourceDirectCallback sends the source's Kad port
// (UDPPort) an OP_DIRECTCALLBACKREQ, and the source connects to us.
type Source struct {
	Type     byte
	UserHash wire.Hash
	// Addr is the TCP endpoint; for firewalled sources it is the address
	// the storing node saw, which is not reachable.
	Addr         netip.AddrPort
	UDPPort      uint16
	Buddy        netip.AddrPort
	BuddyID      wire.Hash
	CryptOptions byte
}

func (s Source) IsFirewalled() bool {
	return s.Type == sourceFirewalled || s.Type == sourceFirewalledLarge
}

type SourcesFound struct {
	Hash    wire.Hash
	Sources []Source
}

type Status struct {
	Nodes        int
	IsFirewalled bool
	// IsUDPFirewalled is the UDP test's verdict, or the last one while a
	// test runs; IsUDPVerified says a test has ever finished.
	IsUDPFirewalled bool
	IsUDPVerified   bool
	// PublicIP is our IPv4 address as the last KADEMLIA_FIREWALLED_RES
	// said; invalid until one did.
	PublicIP netip.Addr
	// UDPPort is our Kad port as others reach it, which our Hello names:
	// the port our NAT shows once a UDP test passed through it, else our
	// own (aMule BaseClient.cpp:1182-1197).
	UDPPort uint16
}

// Callback asks a firewalled source's buddy to have the source connect to
// us for Hash.
type Callback struct {
	Buddy   netip.AddrPort
	BuddyID wire.Hash
	Hash    wire.Hash
}

func (Wanted) isMessage()     {}
func (Callback) isMessage()   {}
func (SourcesFound) isEvent() {}
func (Status) isEvent()       {}

// toSource reads a search result the way CSearch::ProcessResultFile and
// CDownloadQueue::KademliaSearchFile (DownloadQueue.cpp:1600-1670) do. Type
// 2 is skipped ("some clients process it wrong"); firewalled sources, types
// 3, 5 and 6, are useless while we are firewalled ourselves, and type 6
// must say it takes direct callbacks.
func toSource(e kadwire.Entry, isFirewalled bool) (Source, bool) {
	s := Source{UserHash: e.ID}
	var ip netip.Addr
	var tcpPort, buddyPort uint16
	for _, t := range e.Tags {
		if t.Name != "" {
			continue
		}
		switch t.ID {
		case kadwire.TagSourceType:
			s.Type = byte(t.Uint)
		case kadwire.TagSourceIP:
			if t.Uint != 0 {
				ip = kadwire.ToAddr(uint32(t.Uint))
			}
		case kadwire.TagSourcePort:
			tcpPort = uint16(t.Uint)
		case kadwire.TagSourceUPort:
			s.UDPPort = uint16(t.Uint)
		case kadwire.TagServerIP:
			// The buddy's IP is the client's eD2k IP, not a Kad integer:
			// eMule stores CUpDownClient::GetIP() and sends to it unchanged.
			if t.Uint != 0 {
				s.Buddy = netip.AddrPortFrom(wire.ToAddr(uint32(t.Uint)), s.Buddy.Port())
			}
		case kadwire.TagServerPort:
			buddyPort = uint16(t.Uint)
		case kadwire.TagBuddyHash:
			id, ok := parseBuddyID(t)
			if !ok {
				return Source{}, false
			}
			s.BuddyID = id
		case kadwire.TagEncryption:
			s.CryptOptions = byte(t.Uint)
		}
	}
	if ip.IsValid() {
		s.Addr = netip.AddrPortFrom(ip, tcpPort)
	}
	switch s.Type {
	case sourceOpen, sourceOpenLarge:
		return s, ip.IsValid() && tcpPort != 0
	case sourceFirewalled, sourceFirewalledLarge:
		if isFirewalled || !s.Buddy.Addr().IsValid() || buddyPort == 0 || s.BuddyID == (wire.Hash{}) {
			return Source{}, false
		}
		s.Buddy = netip.AddrPortFrom(s.Buddy.Addr(), buddyPort)
		if !ip.IsValid() {
			s.Addr = netip.AddrPortFrom(netip.Addr{}, tcpPort)
		}
		return s, true
	case SourceDirectCallback:
		return s, !isFirewalled && s.CryptOptions&wire.CryptDirectCallback != 0 && ip.IsValid() && s.UDPPort != 0
	}
	return Source{}, false
}

// eMule writes TAG_BUDDYHASH as the hex of the buddy ID's in-memory words,
// which is its Kad wire form (eMule Search.cpp:765); BuddyID holds the hash
// form like every other ID here, so the callback request can encode it
// back. aMule writes and reads the hash form instead (Search.cpp:626, 909),
// so eMule and aMule cannot call back each other's firewalled sources; we
// follow eMule, the larger part of the network.
func buildBuddyHash(id wire.Hash) string {
	return wire.Hash(kadwire.BuildID(nil, id)).String()
}

func parseBuddyID(t wire.Tag) (wire.Hash, bool) {
	raw, err := wire.ParseHash(t.String)
	if t.Type != wire.TagString || err != nil {
		return wire.Hash{}, false
	}
	return kadwire.ParseID(&wire.Reader{Rest: raw[:]}), true
}

// opFirewalledAck is KADEMLIA_FIREWALLED_ACK_RES, which wire/kad does not
// decode.
const opFirewalledAck byte = 0x59

// firewalledAck is KADEMLIA_FIREWALLED_ACK_RES, sent to a node older than
// Kad version 7 whose TCP port we reached (ClientList.cpp:600).
type firewalledAck struct{}

func (firewalledAck) Build(b []byte) []byte { return append(b, wire.ProtocolKad, opFirewalledAck) }
