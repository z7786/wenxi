// Derived from goed2k protocol/server/packet_combiner.go.

// Package server encodes and decodes the packets between a client and an
// eD2k server, over TCP and UDP, including the emule-qt IPv6 extension
// (github.com/ModderMule/emule-qt docs/protocol/ipv6-spec.md).
package server

import (
	"fmt"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const (
	opLogin                 byte = 0x01
	opOfferFiles            byte = 0x15
	opGetSources            byte = 0x19
	opGetSourcesObfu        byte = 0x23
	opCallbackRequest       byte = 0x1C
	opCallbackRequestedIPv6 byte = 0x26
	opServerStatus          byte = 0x34
	opCallbackRequested     byte = 0x35
	opCallbackFailed        byte = 0x36
	opServerMessage         byte = 0x38
	opIDChange              byte = 0x40
	opServerIdent           byte = 0x41
	opFoundSources          byte = 0x42
	opFoundSourcesObfu      byte = 0x44

	opGlobGetSources2  byte = 0x94
	opGlobGetSources   byte = 0x9A
	opGlobServStatReq  byte = 0x96
	opGlobServStatRes  byte = 0x97
	opGlobFoundSources byte = 0x9B
)

// Parse decodes a server TCP packet body. Servers send packed frames
// (0xD4) for eDonkey opcodes, which wire reports as 0xC5, so both protocol
// bytes dispatch on the opcode alone. Anything else is wire.Unknown.
func Parse(protocol, opcode byte, body []byte) (wire.Packet, error) {
	if protocol != wire.ProtocolEDonkey && protocol != wire.ProtocolEMule {
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	r := &wire.Reader{Rest: body}
	var p wire.Packet
	switch opcode {
	case opLogin:
		p = parseLogin(r)
	case opOfferFiles:
		p = parseOfferFiles(r)
	case opGetSources:
		hash, size := parseSizedHash(r)
		p = GetSources{Hash: hash, Size: size}
	case opGetSourcesObfu:
		hash, size := parseSizedHash(r)
		p = GetSources{Hash: hash, Size: size, IsObfu: true}
	case opCallbackRequest:
		p = CallbackRequest{ClientID: r.Uint32()}
	case opCallbackRequestedIPv6:
		addr := r.IPv6()
		p = CallbackRequestedIPv6{Addr: netip.AddrPortFrom(addr, r.Uint16())}
	case opServerStatus:
		p = ServerStatus{Users: r.Uint32(), Files: r.Uint32()}
	case opCallbackRequested:
		p = parseCallbackRequested(r)
	case opCallbackFailed:
		p = CallbackFailed{}
	case opServerMessage:
		p = ServerMessage{Text: r.String()}
	case opIDChange:
		p = parseIDChange(r)
	case opServerIdent:
		p = parseServerIdent(r)
	case opFoundSources:
		p = parseSources(r, false)
	case opFoundSourcesObfu:
		p = parseSources(r, true)
	default:
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	if err := r.Err(); err != nil {
		return nil, fmt.Errorf("server: %T: %w", p, err)
	}
	return p, nil
}

// ParseUDP decodes a server UDP packet body.
func ParseUDP(protocol, opcode byte, body []byte) (wire.Packet, error) {
	if protocol != wire.ProtocolEDonkey {
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	r := &wire.Reader{Rest: body}
	var p wire.Packet
	switch opcode {
	case opGlobGetSources:
		p = parseGlobGetSources(r)
	case opGlobGetSources2:
		p = parseGlobGetSources2(r)
	case opGlobFoundSources:
		p = parseGlobFoundSources(r)
	case opGlobServStatReq:
		p = GlobServStatReq{Challenge: r.Uint32()}
	case opGlobServStatRes:
		p = parseGlobServStatRes(r)
	default:
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	if err := r.Err(); err != nil {
		return nil, fmt.Errorf("server: %T: %w", p, err)
	}
	return p, nil
}
