package client

import (
	"encoding/binary"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
)

// Kad packets that travel between clients (aMule
// include/protocol/ed2k/Client2Client/TCP.h and UDP.h,
// include/protocol/kad2/Client2Client/TCP.h).
const (
	opCallback            byte = 0x99
	opReaskCallbackTCP    byte = 0x9A
	opBuddyPing           byte = 0x9F
	opBuddyPong           byte = 0xA0
	opFirewallCheckUDPReq byte = 0xA7
	opKadFirewallAck      byte = 0xA8

	opReaskCallbackUDP  byte = 0x94
	opDirectCallbackReq byte = 0x95
)

// FirewallCheckUDPReq is OP_FWCHECKUDPREQ: send a KADEMLIA2_FIREWALLUDP to
// each of the sender's Kad ports, encrypted with Key when it is not zero.
type FirewallCheckUDPReq struct {
	InternPort uint16
	ExternPort uint16
	Key        uint32
}

func (p FirewallCheckUDPReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opFirewallCheckUDPReq)
	b = binary.LittleEndian.AppendUint16(b, p.InternPort)
	b = binary.LittleEndian.AppendUint16(b, p.ExternPort)
	return binary.LittleEndian.AppendUint32(b, p.Key)
}

// KadFirewallAck is OP_KAD_FWTCPCHECK_ACK: the Kad node we asked to check
// our TCP port reached it.
type KadFirewallAck struct{}

func (KadFirewallAck) Build(b []byte) []byte { return append(b, wire.ProtocolEMule, opKadFirewallAck) }

// Callback is OP_CALLBACK: a buddy tells the firewalled client it serves
// that the downloader at Endpoint wants File. BuddyID is the ID the client
// published, its Kad ID inverted.
type Callback struct {
	BuddyID  wire.Hash
	File     wire.Hash
	Endpoint netip.AddrPort
}

func (p Callback) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opCallback)
	b = kadwire.BuildID(kadwire.BuildID(b, p.BuddyID), p.File)
	b = binary.LittleEndian.AppendUint32(b, kadwire.ToUint32(p.Endpoint.Addr()))
	return binary.LittleEndian.AppendUint16(b, p.Endpoint.Port())
}

func parseCallback(r *wire.Reader) Callback {
	p := Callback{BuddyID: kadwire.ParseID(r), File: kadwire.ParseID(r)}
	p.Endpoint = netip.AddrPortFrom(kadwire.ToAddr(r.Uint32()), r.Uint16())
	return p
}

// ReaskCallbackTCP is OP_REASKCALLBACKTCP: a buddy passes on the UDP reask
// a downloader at Endpoint sent it for the firewalled client. An IPv6
// Endpoint follows wire.IPv6Sentinel in place of the IPv4 address
// (ipv6-spec §3.5.1).
type ReaskCallbackTCP struct {
	Endpoint netip.AddrPort
	Ping     ReaskFilePing
}

func (p ReaskCallbackTCP) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opReaskCallbackTCP)
	if addr := p.Endpoint.Addr(); addr.Is6() {
		b = wire.BuildIPv6(binary.LittleEndian.AppendUint32(b, wire.IPv6Sentinel), addr)
	} else {
		b = binary.LittleEndian.AppendUint32(b, wire.ToClientID(addr))
	}
	return buildFileRequest(binary.LittleEndian.AppendUint16(b, p.Endpoint.Port()), FileRequest(p.Ping))
}

func parseReaskCallbackTCP(r *wire.Reader) ReaskCallbackTCP {
	addr := wire.ToAddr(r.Uint32())
	if addr == wire.ToAddr(wire.IPv6Sentinel) {
		addr = r.IPv6()
	}
	p := ReaskCallbackTCP{Endpoint: netip.AddrPortFrom(addr, r.Uint16())}
	p.Ping = parseReaskFilePing(r)
	return p
}

// ReaskCallbackUDP is OP_REASKCALLBACKUDP: a downloader's UDP reask of a
// firewalled client, sent to the client's buddy. BuddyID is the ID the
// client published.
type ReaskCallbackUDP struct {
	BuddyID wire.Hash
	Ping    ReaskFilePing
}

func (p ReaskCallbackUDP) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opReaskCallbackUDP)
	return buildFileRequest(append(b, p.BuddyID[:]...), FileRequest(p.Ping))
}

// BuddyPing keeps a buddy link open; the buddy answers with BuddyPong.
type BuddyPing struct{}

func (BuddyPing) Build(b []byte) []byte { return append(b, wire.ProtocolEMule, opBuddyPing) }

type BuddyPong struct{}

func (BuddyPong) Build(b []byte) []byte { return append(b, wire.ProtocolEMule, opBuddyPong) }

// DirectCallbackReq is OP_DIRECTCALLBACKREQ: a downloader asks a
// firewalled client that others reach over UDP to connect to TCPPort.
type DirectCallbackReq struct {
	TCPPort        uint16
	UserHash       wire.Hash
	ConnectOptions byte
}

func (p DirectCallbackReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opDirectCallbackReq)
	b = binary.LittleEndian.AppendUint16(b, p.TCPPort)
	return append(append(b, p.UserHash[:]...), p.ConnectOptions)
}
