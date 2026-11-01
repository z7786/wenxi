// Derived from goed2k protocol/client/packet_combiner.go.

// Package client encodes and decodes the eD2k and eMule peer-to-peer
// packets: TCP between two peers and UDP reasks.
package client

import (
	"fmt"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const (
	opHello               byte = 0x01
	opSendingPart         byte = 0x46
	opRequestParts        byte = 0x47
	opNoFile              byte = 0x48
	opHelloAnswer         byte = 0x4C
	opSetRequestFileID    byte = 0x4F
	opFileStatus          byte = 0x50
	opHashSetRequest      byte = 0x51
	opHashSetAnswer       byte = 0x52
	opStartUploadRequest  byte = 0x54
	opAcceptUploadRequest byte = 0x55
	opCancelTransfer      byte = 0x56
	opOutOfParts          byte = 0x57
	opRequestFileName     byte = 0x58
	opFileNameAnswer      byte = 0x59
	opQueueRank           byte = 0x5C
	opIPv6Changed         byte = 0xAC

	opEmuleInfo         byte = 0x01
	opEmuleInfoAnswer   byte = 0x02
	opCompressedPart    byte = 0x40
	opQueueRanking      byte = 0x60
	opRequestSources    byte = 0x81
	opRequestSources2   byte = 0x83
	opAnswerSources2    byte = 0x84
	opPublicKey         byte = 0x85
	opSignature         byte = 0x86
	opSecureIdentState  byte = 0x87
	opMultiPacket       byte = 0x92
	opMultiPacketAnswer byte = 0x93
	opPublicIPRequest   byte = 0x97
	opPublicIPAnswer    byte = 0x98
	opCompressedPart64  byte = 0xA1
	opSendingPart64     byte = 0xA2
	opRequestParts64    byte = 0xA3
	opMultiPacketExt    byte = 0xA4
	// eMule opcodes.h:284-287; aMule has none of them.
	opMultiPacketExt2       byte = 0xA9
	opMultiPacketAnswerExt2 byte = 0xB0
	opHashSetRequest2       byte = 0xB1
	opHashSetAnswer2        byte = 0xB2

	opAICHRequest         byte = 0x9B
	opAICHAnswer          byte = 0x9C
	opAICHFileHashAnswer  byte = 0x9D
	opAICHFileHashRequest byte = 0x9E

	opReaskFilePing byte = 0x90
	opReaskAck      byte = 0x91
	opFileNotFound  byte = 0x92
	opQueueFull     byte = 0x93
)

// Parse decodes a peer TCP packet body. Opcodes this package does not know
// come back as wire.Unknown.
func Parse(protocol, opcode byte, body []byte) (wire.Packet, error) {
	r := &wire.Reader{Rest: body}
	var p wire.Packet
	switch protocol {
	case wire.ProtocolEDonkey:
		p = parseEDonkey(r, opcode)
	case wire.ProtocolEMule:
		p = parseEMule(r, opcode)
	}
	if p == nil {
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	if err := r.Err(); err != nil {
		return nil, fmt.Errorf("client: %T: %w", p, err)
	}
	return p, nil
}

// ParseUDP decodes a peer UDP packet body.
func ParseUDP(protocol, opcode byte, body []byte) (wire.Packet, error) {
	if protocol != wire.ProtocolEMule {
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	r := &wire.Reader{Rest: body}
	var p wire.Packet
	switch opcode {
	case opReaskFilePing:
		p = parseReaskFilePing(r)
	case opReaskAck:
		p = parseReaskAck(r)
	case opFileNotFound:
		p = FileNotFound{}
	case opQueueFull:
		p = QueueFull{}
	case opReaskCallbackUDP:
		p = ReaskCallbackUDP{BuddyID: r.Hash(), Ping: parseReaskFilePing(r)}
	case opDirectCallbackReq:
		p = DirectCallbackReq{TCPPort: r.Uint16(), UserHash: r.Hash(), ConnectOptions: r.Uint8()}
	default:
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	if err := r.Err(); err != nil {
		return nil, fmt.Errorf("client: %T: %w", p, err)
	}
	return p, nil
}

func parseEDonkey(r *wire.Reader, opcode byte) wire.Packet {
	switch opcode {
	case opHello:
		r.Uint8()
		return parseHello(r)
	case opHelloAnswer:
		return HelloAnswer(parseHello(r))
	case opRequestFileName:
		return parseFileRequest(r)
	case opFileNameAnswer:
		return FileNameAnswer{Hash: r.Hash(), Name: r.String()}
	case opSetRequestFileID:
		return SetRequestFileID{Hash: r.Hash()}
	case opFileStatus:
		return FileStatus{Hash: r.Hash(), Parts: r.Bitfield()}
	case opNoFile:
		return NoFile{Hash: r.Hash()}
	case opHashSetRequest:
		return HashSetRequest{Hash: r.Hash()}
	case opHashSetAnswer:
		return parseHashSetAnswer(r)
	case opStartUploadRequest:
		var s StartUploadRequest
		if r.Len() >= 16 {
			s.Hash = r.Hash()
		}
		return s
	case opAcceptUploadRequest:
		return AcceptUploadRequest{}
	case opCancelTransfer:
		return CancelTransfer{}
	case opOutOfParts:
		return OutOfParts{}
	case opQueueRank:
		return QueueRank{Rank: r.Uint32()}
	case opRequestParts:
		return parseRequestParts(r, false)
	case opSendingPart:
		return parseSendingPart(r, false)
	case opIPv6Changed:
		return IPv6Changed{Addr: r.IPv6()}
	}
	return nil
}

func parseEMule(r *wire.Reader, opcode byte) wire.Packet {
	switch opcode {
	case opEmuleInfo:
		return parseEmuleInfo(r)
	case opEmuleInfoAnswer:
		return EmuleInfoAnswer(parseEmuleInfo(r))
	case opQueueRanking:
		return QueueRanking{Rank: r.Uint16()}
	case opRequestParts64:
		return parseRequestParts(r, true)
	case opSendingPart64:
		return parseSendingPart(r, true)
	case opCompressedPart:
		return parseCompressedPart(r, false)
	case opCompressedPart64:
		return parseCompressedPart(r, true)
	case opRequestSources:
		return requestSources{Hash: r.Hash()}
	case opRequestSources2:
		return RequestSources2{Version: r.Uint8(), Options: r.Uint16(), Hash: r.Hash()}
	case opAnswerSources2:
		return parseAnswerSources2(r)
	case opSecureIdentState:
		return SecureIdentState{State: r.Uint8(), Challenge: r.Uint32()}
	case opPublicKey:
		return PublicKey{Key: r.Bytes(int(r.Uint8()))}
	case opSignature:
		return parseSignature(r)
	case opMultiPacket:
		return parseMultiPacket(r)
	case opMultiPacketExt:
		return parseMultiPacketExt(r)
	case opMultiPacketAnswer:
		return parseMultiPacketAnswer(r)
	case opMultiPacketExt2:
		return parseMultiPacketExt2(r)
	case opMultiPacketAnswerExt2:
		return parseMultiPacketAnswerExt2(r)
	case opHashSetRequest2:
		return parseHashSetRequest2(r)
	case opAICHFileHashRequest:
		return AICHFileHashRequest{Hash: r.Hash()}
	case opAICHFileHashAnswer:
		return AICHFileHashAnswer{Hash: r.Hash(), Root: r.AICHHash()}
	case opAICHRequest:
		return AICHRequest{Hash: r.Hash(), Part: r.Uint16(), Root: r.AICHHash()}
	case opAICHAnswer:
		return parseAICHAnswer(r)
	case opPublicIPRequest:
		return PublicIPRequest{}
	case opPublicIPAnswer:
		return PublicIPAnswer{Addr: wire.ToAddr(r.Uint32())}
	case opIPv6Changed:
		// emule-qt accepts it under either protocol byte; so do we.
		return IPv6Changed{Addr: r.IPv6()}
	case opCallback:
		return parseCallback(r)
	case opReaskCallbackTCP:
		return parseReaskCallbackTCP(r)
	case opBuddyPing:
		return BuddyPing{}
	case opBuddyPong:
		return BuddyPong{}
	case opFirewallCheckUDPReq:
		return FirewallCheckUDPReq{InternPort: r.Uint16(), ExternPort: r.Uint16(), Key: r.Uint32()}
	case opKadFirewallAck:
		return KadFirewallAck{}
	}
	return nil
}
