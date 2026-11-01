// Derived from goed2k protocol/kad/types.go, packets.go and packet_combiner.go.

// Package kad encodes and decodes Kademlia 2 UDP packets. Kad is IPv4 only.
package kad

import (
	"encoding/binary"
	"fmt"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const (
	opBootstrapReq        byte = 0x01
	opBootstrapRes        byte = 0x09
	opHelloReq            byte = 0x11
	opHelloRes            byte = 0x19
	opReq                 byte = 0x21
	opHelloResAck         byte = 0x22
	opRes                 byte = 0x29
	opSearchSourcesReq    byte = 0x34
	opSearchRes           byte = 0x3B
	opPublishSourcesReq   byte = 0x44
	opPublishRes          byte = 0x4B
	opLegacyFirewalledReq byte = 0x50
	opFindBuddyReq        byte = 0x51
	opCallbackReq         byte = 0x52
	opFirewalledReq       byte = 0x53
	opFirewalledRes       byte = 0x58
	opFindBuddyRes        byte = 0x5A
	opPing                byte = 0x60
	opPong                byte = 0x61
	opFirewalledUDP       byte = 0x62
)

// Version is the Kad version we announce: 6 brought obfuscation and the UDP
// firewall test, 7 KADEMLIA_FIREWALLED2_REQ and the TCP firewall
// acknowledgement, 8 TAG_KADMISCOPTIONS and HELLO_RES_ACK. aMule stops at 8
// (Constants.h:29); eMule's 9 is about keyword storage, which Kelpie does
// not do.
const Version byte = 0x08

// Req.SearchType values: how many contacts the asker wants back.
const (
	FindValue byte = 0x02
	Store     byte = 0x04
	FindNode  byte = 0x0B
)

// Source tag IDs carried in SearchEntry.Tags, and TagKadMiscOptions, which a
// Hello carries.
const (
	TagFileSize byte = 0x02
	// TagKadMiscOptions holds the MiscOption bits (FileTags.h:114).
	TagKadMiscOptions byte = 0xF2
	TagEncryption     byte = 0xF3
	TagBuddyHash      byte = 0xF8
	TagServerPort     byte = 0xFA
	TagServerIP       byte = 0xFB
	TagSourceUPort    byte = 0xFC
	TagSourcePort     byte = 0xFD
	TagSourceIP       byte = 0xFE
	TagSourceType     byte = 0xFF
)

// IsDatagram reports whether a UDP datagram is a plain Kad one by its
// protocol byte. Kad shares its UDP port with eD2k, whose datagrams, and
// obfuscated ones of either, start with other bytes.
func IsDatagram(data []byte) bool {
	return len(data) > 0 && (data[0] == wire.ProtocolKad || data[0] == wire.ProtocolKadPacked)
}

// Parse decodes a Kad packet body; wire.ParseDatagram has already inflated
// packed (0xE5) packets to 0xE4. Opcodes not listed here, including the
// keyword and notes packets Kelpie does not use, come back as wire.Unknown.
func Parse(protocol, opcode byte, body []byte) (wire.Packet, error) {
	if protocol != wire.ProtocolKad {
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	r := &wire.Reader{Rest: body}
	var p wire.Packet
	switch opcode {
	case opBootstrapReq:
		p = BootstrapReq{}
	case opBootstrapRes:
		p = BootstrapRes{ID: ParseID(r), TCPPort: r.Uint16(), Version: r.Uint8(), Contacts: parseContacts(r, int(r.Uint16()))}
	case opHelloReq:
		p = HelloReq(parseHello(r))
	case opHelloRes:
		p = HelloRes(parseHello(r))
	case opHelloResAck:
		p = HelloResAck(parseEntry(r))
	case opReq:
		p = Req{SearchType: r.Uint8(), Target: ParseID(r), Receiver: ParseID(r)}
	case opRes:
		p = Res{Target: ParseID(r), Contacts: parseContacts(r, int(r.Uint8()))}
	case opSearchSourcesReq:
		p = SearchSourcesReq{Target: ParseID(r), StartPos: r.Uint16(), Size: r.Uint64()}
	case opSearchRes:
		p = SearchRes{Source: ParseID(r), Target: ParseID(r), Results: parseEntries(r, int(r.Uint16()))}
	case opPublishSourcesReq:
		p = PublishSourcesReq{FileID: ParseID(r), Source: parseEntry(r)}
	case opPublishRes:
		p = PublishRes{FileID: ParseID(r), Load: r.Uint8()}
	case opLegacyFirewalledReq:
		p = LegacyFirewalledReq{TCPPort: r.Uint16()}
	case opFirewalledReq:
		p = FirewalledReq{TCPPort: r.Uint16(), ID: ParseID(r), Options: r.Uint8()}
	case opFirewalledRes:
		p = FirewalledRes{Addr: parseAddr(r)}
	case opPing:
		p = Ping{}
	case opPong:
		p = Pong{UDPPort: r.Uint16()}
	case opFindBuddyReq:
		p = FindBuddyReq{Target: ParseID(r), UserHash: ParseID(r), TCPPort: r.Uint16()}
	case opFindBuddyRes:
		p = parseFindBuddyRes(r)
	case opCallbackReq:
		p = CallbackReq{BuddyID: ParseID(r), Hash: ParseID(r), TCPPort: r.Uint16()}
	case opFirewalledUDP:
		p = FirewalledUDP{ErrorCode: r.Uint8(), Port: r.Uint16()}
	default:
		return wire.Unknown{Proto: protocol, Op: opcode, Body: body}, nil
	}
	if err := r.Err(); err != nil {
		return nil, fmt.Errorf("kad: %T: %w", p, err)
	}
	return p, nil
}

// ParseID reads a 128-bit ID. Kad writes one as four little-endian uint32
// words, so each group of four bytes is reversed against the ID's
// big-endian byte form.
func ParseID(r *wire.Reader) wire.Hash {
	var id wire.Hash
	raw := r.Bytes(16)
	for i := range raw {
		id[i/4*4+3-i%4] = raw[i]
	}
	return id
}

// BuildID writes id in Kad's wire form.
func BuildID(b []byte, id wire.Hash) []byte {
	for i := range id {
		b = append(b, id[i/4*4+3-i%4])
	}
	return b
}

// Kad stores IPv4 addresses as host-order integers, written little-endian:
// the reverse of eD2k's a.b.c.d byte order.
func parseAddr(r *wire.Reader) netip.Addr {
	v := r.Uint32()
	if v == 0 {
		return netip.Addr{}
	}
	return ToAddr(v)
}

func buildAddr(b []byte, addr netip.Addr) []byte {
	return binary.LittleEndian.AppendUint32(b, ToUint32(addr))
}

// ToAddr converts a Kad IPv4 integer, as carried in packets and in the
// TagSourceIP tag, to an address. TagServerIP holds a buddy IP in eD2k byte
// order (eMule publishes the buddy's GetIP()); decode it with wire.ToAddr.
func ToAddr(v uint32) netip.Addr {
	var a [4]byte
	binary.BigEndian.PutUint32(a[:], v)
	return netip.AddrFrom4(a)
}

// ToUint32 converts an IPv4 address to Kad's integer form; other addresses
// give 0.
func ToUint32(addr netip.Addr) uint32 {
	if !addr.Is4() {
		return 0
	}
	a := addr.As4()
	return binary.BigEndian.Uint32(a[:])
}

// Contact is one Kad node as packets carry it.
type Contact struct {
	ID      wire.Hash
	Addr    netip.Addr
	UDPPort uint16
	TCPPort uint16
	Version byte
}

func buildContact(b []byte, c Contact) []byte {
	b = buildAddr(BuildID(b, c.ID), c.Addr)
	b = binary.LittleEndian.AppendUint16(b, c.UDPPort)
	b = binary.LittleEndian.AppendUint16(b, c.TCPPort)
	return append(b, c.Version)
}

func parseContacts(r *wire.Reader, count int) []Contact {
	if count*25 > r.Len() {
		r.SetErr(wire.ErrShort)
		return nil
	}
	if count == 0 {
		return nil
	}
	out := make([]Contact, count)
	for i := range out {
		out[i] = Contact{ID: ParseID(r), Addr: parseAddr(r), UDPPort: r.Uint16(), TCPPort: r.Uint16(), Version: r.Uint8()}
	}
	return out
}

// Entry is an ID with tags: a search result or a published source.
type Entry struct {
	ID   wire.Hash
	Tags []wire.Tag
}

func buildEntry(b []byte, e Entry) []byte { return buildTags(BuildID(b, e.ID), e.Tags) }

// buildTags writes a one-byte count and the tags. Kad tags always use the
// classic form with a uint16 name length; eMule's Kad reader rejects the
// compact eD2k form.
func buildTags(b []byte, tags []wire.Tag) []byte {
	b = append(b, byte(len(tags)))
	for _, t := range tags {
		b = wire.BuildTag(b, t)
	}
	return b
}

func parseEntry(r *wire.Reader) Entry {
	e := Entry{ID: ParseID(r)}
	e.Tags = parseTags(r, int(r.Uint8()))
	return e
}

func parseEntries(r *wire.Reader, count int) []Entry {
	if count*17 > r.Len() {
		r.SetErr(wire.ErrShort)
		return nil
	}
	var out []Entry
	for range count {
		out = append(out, parseEntry(r))
	}
	return out
}

func parseTags(r *wire.Reader, count int) []wire.Tag {
	var out []wire.Tag
	for range count {
		out = append(out, r.Tag())
	}
	return out
}

type BootstrapReq struct{}

func (BootstrapReq) Build(b []byte) []byte { return append(b, wire.ProtocolKad, opBootstrapReq) }

type BootstrapRes struct {
	ID       wire.Hash
	TCPPort  uint16
	Version  byte
	Contacts []Contact
}

func (p BootstrapRes) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opBootstrapRes)
	b = binary.LittleEndian.AppendUint16(BuildID(b, p.ID), p.TCPPort)
	b = binary.LittleEndian.AppendUint16(append(b, p.Version), uint16(len(p.Contacts)))
	for _, c := range p.Contacts {
		b = buildContact(b, c)
	}
	return b
}

// Hello is the body shared by HelloReq and HelloRes.
type Hello struct {
	ID      wire.Hash
	TCPPort uint16
	Version byte
	Tags    []wire.Tag
}

type HelloReq Hello

type HelloRes Hello

func (h HelloReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opHelloReq)
	return buildHello(b, Hello(h))
}
func (h HelloRes) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opHelloRes)
	return buildHello(b, Hello(h))
}

func buildHello(b []byte, h Hello) []byte {
	b = binary.LittleEndian.AppendUint16(BuildID(b, h.ID), h.TCPPort)
	return buildTags(append(b, h.Version), h.Tags)
}

func parseHello(r *wire.Reader) Hello {
	h := Hello{ID: ParseID(r), TCPPort: r.Uint16(), Version: r.Uint8()}
	h.Tags = parseTags(r, int(r.Uint8()))
	return h
}

// TagKadMiscOptions bits, as SendMyDetails sets them
// (KademliaUDPListener.cpp:133).
const (
	MiscUDPFirewalled byte = 0x01
	MiscTCPFirewalled byte = 0x02
	MiscRequestsAck   byte = 0x04
)

// HelloResAck is KADEMLIA2_HELLO_RES_ACK: the third leg of a hello, sent when
// a HelloRes asks for it, which proves the sender's IP.
type HelloResAck struct {
	ID   wire.Hash
	Tags []wire.Tag
}

func (p HelloResAck) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opHelloResAck)
	return buildEntry(b, Entry(p))
}

type Req struct {
	SearchType byte
	Target     wire.Hash
	Receiver   wire.Hash
}

func (p Req) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opReq)
	return BuildID(BuildID(append(b, p.SearchType), p.Target), p.Receiver)
}

type Res struct {
	Target   wire.Hash
	Contacts []Contact
}

func (p Res) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opRes)
	b = append(BuildID(b, p.Target), byte(len(p.Contacts)))
	for _, c := range p.Contacts {
		b = buildContact(b, c)
	}
	return b
}

type SearchSourcesReq struct {
	Target   wire.Hash
	StartPos uint16
	Size     uint64
}

func (p SearchSourcesReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opSearchSourcesReq)
	b = binary.LittleEndian.AppendUint16(BuildID(b, p.Target), p.StartPos)
	return binary.LittleEndian.AppendUint64(b, p.Size)
}

type SearchRes struct {
	Source  wire.Hash
	Target  wire.Hash
	Results []Entry
}

func (p SearchRes) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opSearchRes)
	b = BuildID(BuildID(b, p.Source), p.Target)
	b = binary.LittleEndian.AppendUint16(b, uint16(len(p.Results)))
	for _, e := range p.Results {
		b = buildEntry(b, e)
	}
	return b
}

type PublishSourcesReq struct {
	FileID wire.Hash
	Source Entry
}

func (p PublishSourcesReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opPublishSourcesReq)
	return buildEntry(BuildID(b, p.FileID), p.Source)
}

// PublishRes acknowledges a publish; Load is the node's fill level in
// percent.
type PublishRes struct {
	FileID wire.Hash
	Load   byte
}

func (p PublishRes) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opPublishRes)
	return append(BuildID(b, p.FileID), p.Load)
}

// LegacyFirewalledReq is the Kad 1 firewall check, still sent by old nodes.
type LegacyFirewalledReq struct{ TCPPort uint16 }

func (p LegacyFirewalledReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opLegacyFirewalledReq)
	return binary.LittleEndian.AppendUint16(b, p.TCPPort)
}

// FirewalledReq asks a node to connect back to TCPPort. ID is our user
// hash.
type FirewalledReq struct {
	TCPPort uint16
	ID      wire.Hash
	Options byte
}

func (p FirewalledReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opFirewalledReq)
	return append(BuildID(binary.LittleEndian.AppendUint16(b, p.TCPPort), p.ID), p.Options)
}

// FirewalledRes tells us the address the node sees us at.
type FirewalledRes struct{ Addr netip.Addr }

func (p FirewalledRes) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opFirewalledRes)
	return buildAddr(b, p.Addr)
}

// FirewalledUDP is the answer to a UDP firewall test: Port is the UDP port
// it was sent to; a non-zero ErrorCode says the tester knew us already, so
// the result proves nothing.
type FirewalledUDP struct {
	ErrorCode byte
	Port      uint16
}

func (p FirewalledUDP) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opFirewalledUDP)
	return binary.LittleEndian.AppendUint16(append(b, p.ErrorCode), p.Port)
}

type Ping struct{}

func (Ping) Build(b []byte) []byte { return append(b, wire.ProtocolKad, opPing) }

// Pong reports the UDP port the node saw our ping come from.
type Pong struct{ UDPPort uint16 }

func (p Pong) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opPong)
	return binary.LittleEndian.AppendUint16(b, p.UDPPort)
}

// FindBuddyReq asks an open node to be our buddy. Target is the ID our
// lookup looked for, our Kad ID inverted, which callbacks will carry.
type FindBuddyReq struct {
	Target   wire.Hash
	UserHash wire.Hash
	TCPPort  uint16
}

func (p FindBuddyReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opFindBuddyReq)
	return binary.LittleEndian.AppendUint16(BuildID(BuildID(b, p.Target), p.UserHash), p.TCPPort)
}

// FindBuddyRes accepts a FindBuddyReq. Nodes since Kad version 7 add their
// obfuscation options when the request was obfuscated.
type FindBuddyRes struct {
	Target     wire.Hash
	UserHash   wire.Hash
	TCPPort    uint16
	HasOptions bool
	Options    byte
}

func (p FindBuddyRes) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opFindBuddyRes)
	b = binary.LittleEndian.AppendUint16(BuildID(BuildID(b, p.Target), p.UserHash), p.TCPPort)
	if p.HasOptions {
		b = append(b, p.Options)
	}
	return b
}

func parseFindBuddyRes(r *wire.Reader) FindBuddyRes {
	p := FindBuddyRes{Target: ParseID(r), UserHash: ParseID(r), TCPPort: r.Uint16()}
	if r.Len() > 0 {
		p.HasOptions, p.Options = true, r.Uint8()
	}
	return p
}

// CallbackReq is what a downloader sends a firewalled source's buddy: the
// buddy ID, the file and the downloader's TCP port. The buddy forwards it
// as OP_CALLBACK over its TCP link to the source.
type CallbackReq struct {
	BuddyID wire.Hash
	Hash    wire.Hash
	TCPPort uint16
}

func (p CallbackReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolKad, opCallbackReq)
	return binary.LittleEndian.AppendUint16(BuildID(BuildID(b, p.BuddyID), p.Hash), p.TCPPort)
}
