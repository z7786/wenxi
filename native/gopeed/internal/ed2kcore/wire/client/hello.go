// Derived from goed2k protocol/client/hello.go, hello_answer.go and extended_handshake.go.
package client

import (
	"encoding/binary"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// Hello tag IDs (CT_*).
const (
	tagName         byte = 0x01
	tagVersion      byte = 0x11
	tagModVersion   byte = 0x55
	tagUDPPorts     byte = 0xF9
	tagBuddyIP      byte = 0xFC
	tagBuddyUDP     byte = 0xFD
	tagMiscOptions1 byte = 0xFA
	tagEmuleVersion byte = 0xFB
	tagMiscOptions2 byte = 0xFE

	// The IPv6 extension reuses the tags emule-qt defined (ipv6-spec §1.1)
	// instead of inventing Kelpie-only numbers, so Kelpie peers also reach
	// eMuleQt and the eMule fork it agreed with over IPv6.
	tagModMiscOptions byte = 0xAA
	tagYourIP         byte = 0xAD
	tagIPv6           byte = 0xAE
)

// EDonkeyVersion is the value every eMule-family client sends in CT_VERSION.
const EDonkeyVersion = 0x3C

// CT_MOD_MISCOPTIONS bits Kelpie sends (emule-qt ipv6-spec §1.3).
const (
	ModMiscExtendedSources         uint32 = 0x01
	ModMiscExtendedSourcesSkipTags uint32 = 0x20
)

// Hello is OP_HELLO and OP_HELLOANSWER. The known tags are lifted into
// fields: a field at its zero value is not sent. Tags holds every other tag
// in arrival order.
type Hello struct {
	UserHash     wire.Hash
	ClientID     uint32
	Port         uint16
	Server       netip.AddrPort
	Name         string
	Version      uint32
	ModName      string
	UDPPort      uint16
	KadPort      uint16
	Misc1        MiscOptions1
	Misc2        MiscOptions2
	EmuleVersion uint32
	ModMisc      uint32
	// Buddy is the IP and UDP port of the sender's Kad buddy, set while
	// the sender is firewalled and has one.
	Buddy netip.AddrPort
	// YourIP is the address the sender sees us at, a vote rather than a
	// fact (ipv6-spec §3.1).
	YourIP netip.Addr
	IPv6   netip.Addr
	Tags   []wire.Tag
}

// HelloAnswer has the same body as Hello minus the leading hash length.
type HelloAnswer Hello

func (h Hello) Build(b []byte) []byte {
	return buildHello(append(b, wire.ProtocolEDonkey, opHello, 16), h)
}

func (h HelloAnswer) Build(b []byte) []byte {
	return buildHello(append(b, wire.ProtocolEDonkey, opHelloAnswer), Hello(h))
}

func parseHello(r *wire.Reader) Hello {
	h := Hello{UserHash: r.Hash(), ClientID: r.Uint32(), Port: r.Uint16()}
	for _, t := range r.Tags() {
		if !setHelloField(&h, t) {
			h.Tags = append(h.Tags, t)
		}
	}
	h.Server = r.AddrPort()
	// Some clients append a signature after the server endpoint; it carries
	// nothing we use.
	r.Rest = nil
	return h
}

func setHelloField(h *Hello, t wire.Tag) bool {
	if t.Name != "" {
		return false
	}
	isUint := t.Type == wire.TagUint8 || t.Type == wire.TagUint16 || t.Type == wire.TagUint32
	switch {
	case t.ID == tagName && t.Type == wire.TagString:
		h.Name = t.String
	case t.ID == tagVersion && isUint:
		h.Version = uint32(t.Uint)
	case t.ID == tagModVersion && t.Type == wire.TagString:
		h.ModName = t.String
	case t.ID == tagUDPPorts && isUint:
		h.KadPort = uint16(t.Uint >> 16)
		h.UDPPort = uint16(t.Uint)
	case t.ID == tagBuddyIP && isUint:
		h.Buddy = netip.AddrPortFrom(wire.ToAddr(uint32(t.Uint)), h.Buddy.Port())
	case t.ID == tagBuddyUDP && isUint:
		h.Buddy = netip.AddrPortFrom(h.Buddy.Addr(), uint16(t.Uint))
	case t.ID == tagMiscOptions1 && isUint:
		h.Misc1 = parseMiscOptions1(uint32(t.Uint))
	case t.ID == tagMiscOptions2 && isUint:
		h.Misc2 = parseMiscOptions2(uint32(t.Uint))
	case t.ID == tagEmuleVersion && isUint:
		h.EmuleVersion = uint32(t.Uint)
	case t.ID == tagModMiscOptions && isUint:
		h.ModMisc = uint32(t.Uint)
	case t.ID == tagYourIP && isUint:
		h.YourIP = wire.ToAddr(uint32(t.Uint))
	case t.ID == tagYourIP && t.Type == wire.TagHash:
		h.YourIP = netip.AddrFrom16(t.Hash)
	case t.ID == tagIPv6 && t.Type == wire.TagHash:
		h.IPv6 = netip.AddrFrom16(t.Hash)
	default:
		return false
	}
	return true
}

func buildHello(b []byte, h Hello) []byte {
	var tags []wire.Tag
	addString := func(id byte, s string) {
		if s != "" {
			tags = append(tags, wire.Tag{Type: wire.TagString, ID: id, String: s})
		}
	}
	addUint := func(id byte, v uint32) {
		if v != 0 {
			tags = append(tags, wire.Tag{Type: wire.TagUint32, ID: id, Uint: uint64(v)})
		}
	}
	addAddr := func(id byte, addr netip.Addr) {
		switch {
		case addr.Is4():
			addUint(id, wire.ToClientID(addr))
		case addr.Is6():
			tags = append(tags, wire.Tag{Type: wire.TagHash, ID: id, Hash: addr.As16()})
		}
	}
	addString(tagName, h.Name)
	addUint(tagVersion, h.Version)
	addUint(tagUDPPorts, uint32(h.KadPort)<<16|uint32(h.UDPPort))
	addAddr(tagBuddyIP, h.Buddy.Addr())
	addUint(tagBuddyUDP, uint32(h.Buddy.Port()))
	addUint(tagMiscOptions1, h.Misc1.toUint32())
	addUint(tagMiscOptions2, h.Misc2.toUint32())
	addUint(tagEmuleVersion, h.EmuleVersion)
	addString(tagModVersion, h.ModName)
	addUint(tagModMiscOptions, h.ModMisc)
	addAddr(tagYourIP, h.YourIP)
	addAddr(tagIPv6, h.IPv6)
	tags = append(tags, h.Tags...)

	b = append(b, h.UserHash[:]...)
	b = binary.LittleEndian.AppendUint32(b, h.ClientID)
	b = binary.LittleEndian.AppendUint16(b, h.Port)
	b = wire.BuildTags(b, tags)
	return wire.BuildAddrPort(b, h.Server)
}

// MiscOptions1 is CT_EMULE_MISCOPTIONS1, the eMule capability word sent in
// Hello. Version fields are 4 bits wide except AICHVersion (3 bits).
type MiscOptions1 struct {
	AICHVersion             byte
	IsUnicode               bool
	UDPVersion              byte
	DataCompressionVersion  byte
	SecureIdentVersion      byte
	SourceExchange1Version  byte
	ExtendedRequestsVersion byte
	AcceptCommentVersion    byte
	IsSharedFilesHidden     bool
	HasMultiPacket          bool
	HasPreview              bool
}

func parseMiscOptions1(v uint32) MiscOptions1 {
	return MiscOptions1{
		AICHVersion:             byte(v>>29) & 0x07,
		IsUnicode:               v>>28&1 != 0,
		UDPVersion:              byte(v>>24) & 0x0F,
		DataCompressionVersion:  byte(v>>20) & 0x0F,
		SecureIdentVersion:      byte(v>>16) & 0x0F,
		SourceExchange1Version:  byte(v>>12) & 0x0F,
		ExtendedRequestsVersion: byte(v>>8) & 0x0F,
		AcceptCommentVersion:    byte(v>>4) & 0x0F,
		IsSharedFilesHidden:     v>>2&1 != 0,
		HasMultiPacket:          v>>1&1 != 0,
		HasPreview:              v&1 != 0,
	}
}

func (m MiscOptions1) toUint32() uint32 {
	return uint32(m.AICHVersion&0x07)<<29 |
		toBit(m.IsUnicode)<<28 |
		uint32(m.UDPVersion&0x0F)<<24 |
		uint32(m.DataCompressionVersion&0x0F)<<20 |
		uint32(m.SecureIdentVersion&0x0F)<<16 |
		uint32(m.SourceExchange1Version&0x0F)<<12 |
		uint32(m.ExtendedRequestsVersion&0x0F)<<8 |
		uint32(m.AcceptCommentVersion&0x0F)<<4 |
		toBit(m.IsSharedFilesHidden)<<2 |
		toBit(m.HasMultiPacket)<<1 |
		toBit(m.HasPreview)
}

// MiscOptions2 is CT_EMULE_MISCOPTIONS2.
type MiscOptions2 struct {
	KadVersion           byte
	HasLargeFiles        bool
	HasExtMultiPacket    bool
	CanCrypt             bool
	IsCryptRequested     bool
	IsCryptRequired      bool
	HasSourceExchange2   bool
	HasCaptcha           bool
	HasDirectUDPCallback bool
	HasFileIdentifiers   bool
}

func parseMiscOptions2(v uint32) MiscOptions2 {
	return MiscOptions2{
		KadVersion:           byte(v) & 0x0F,
		HasLargeFiles:        v>>4&1 != 0,
		HasExtMultiPacket:    v>>5&1 != 0,
		CanCrypt:             v>>7&1 != 0,
		IsCryptRequested:     v>>8&1 != 0,
		IsCryptRequired:      v>>9&1 != 0,
		HasSourceExchange2:   v>>10&1 != 0,
		HasCaptcha:           v>>11&1 != 0,
		HasDirectUDPCallback: v>>12&1 != 0,
		HasFileIdentifiers:   v>>13&1 != 0,
	}
}

func (m MiscOptions2) toUint32() uint32 {
	return uint32(m.KadVersion&0x0F) |
		toBit(m.HasLargeFiles)<<4 |
		toBit(m.HasExtMultiPacket)<<5 |
		toBit(m.CanCrypt)<<7 |
		toBit(m.IsCryptRequested)<<8 |
		toBit(m.IsCryptRequired)<<9 |
		toBit(m.HasSourceExchange2)<<10 |
		toBit(m.HasCaptcha)<<11 |
		toBit(m.HasDirectUDPCallback)<<12 |
		toBit(m.HasFileIdentifiers)<<13
}

func toBit(v bool) uint32 {
	if v {
		return 1
	}
	return 0
}

// EmuleInfo is OP_EMULEINFO, the pre-Hello-tags capability exchange. Its
// tags (ET_*) stay raw: modern clients repeat them in Hello.
type EmuleInfo struct {
	Version         byte
	ProtocolVersion byte
	Tags            []wire.Tag
}

type EmuleInfoAnswer EmuleInfo

// ET_* tag IDs carried by EmuleInfo.
const (
	InfoCompression      byte = 0x20
	InfoUDPPort          byte = 0x21
	InfoUDPVersion       byte = 0x22
	InfoExtendedRequest  byte = 0x25
	InfoCompatibleClient byte = 0x26
	InfoFeatures         byte = 0x27
)

func (e EmuleInfo) Build(b []byte) []byte {
	return buildEmuleInfo(append(b, wire.ProtocolEMule, opEmuleInfo), e)
}

func (e EmuleInfoAnswer) Build(b []byte) []byte {
	return buildEmuleInfo(append(b, wire.ProtocolEMule, opEmuleInfoAnswer), EmuleInfo(e))
}

func buildEmuleInfo(b []byte, e EmuleInfo) []byte {
	return wire.BuildTags(append(b, e.Version, e.ProtocolVersion), e.Tags)
}

func parseEmuleInfo(r *wire.Reader) EmuleInfo {
	e := EmuleInfo{Version: r.Uint8(), ProtocolVersion: r.Uint8()}
	if r.Len() > 0 {
		e.Tags = r.Tags()
	}
	return e
}
