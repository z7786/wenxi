// Derived from goed2k protocol/server (login_request.go, id_change.go,
// message.go, status.go, get_file_sources.go, found_file_sources.go,
// callback_request*.go, offer_files.go).
package server

import (
	"encoding/binary"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// Login capability bits (CT_SERVER_FLAGS, client to server).
const (
	CapZlib         uint32 = 0x0001
	CapNewTags      uint32 = 0x0008
	CapUnicode      uint32 = 0x0010
	CapLargeFiles   uint32 = 0x0100
	CapSupportCrypt uint32 = 0x0200
	CapRequestCrypt uint32 = 0x0400
)

// Server TCP flags (IDChange.Flags, server to client).
const (
	FlagCompression    uint32 = 0x0001
	FlagNewTags        uint32 = 0x0008
	FlagUnicode        uint32 = 0x0010
	FlagLargeFiles     uint32 = 0x0100
	FlagTCPObfuscation uint32 = 0x0400
)

const (
	tagName         byte = 0x01
	tagDescription  byte = 0x0B
	tagVersion      byte = 0x11
	tagServerFlags  byte = 0x20
	tagEmuleVersion byte = 0xFB
	tagIPv6Status   byte = 0xAB
	tagYourIP       byte = 0xAD
	tagIPv6         byte = 0xAE
	tagServerIPv6   byte = 0xAF
)

// Login is OP_LOGINREQUEST. Its known tags are lifted into fields; a field
// at its zero value is not sent, and Tags holds everything else. IPv6 goes
// with the login flag 0x1000 (ipv6-spec §4.1).
type Login struct {
	UserHash     wire.Hash
	ClientID     uint32
	Port         uint16
	Name         string
	Version      uint32
	Flags        uint32
	EmuleVersion uint32
	IPv6         netip.Addr
	Tags         []wire.Tag
}

func (l Login) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opLogin)
	var tags []wire.Tag
	if l.Name != "" {
		tags = append(tags, wire.Tag{Type: wire.TagString, ID: tagName, String: l.Name})
	}
	for _, t := range []struct {
		id byte
		v  uint32
	}{{tagVersion, l.Version}, {tagServerFlags, l.Flags}, {tagEmuleVersion, l.EmuleVersion}} {
		if t.v != 0 {
			tags = append(tags, wire.Tag{Type: wire.TagUint32, ID: t.id, Uint: uint64(t.v)})
		}
	}
	if l.IPv6.IsValid() {
		tags = append(tags, wire.Tag{Type: wire.TagHash, ID: tagIPv6, Hash: l.IPv6.As16()})
	}
	tags = append(tags, l.Tags...)
	b = append(b, l.UserHash[:]...)
	b = binary.LittleEndian.AppendUint32(b, l.ClientID)
	b = binary.LittleEndian.AppendUint16(b, l.Port)
	return wire.BuildTags(b, tags)
}

func parseLogin(r *wire.Reader) Login {
	l := Login{UserHash: r.Hash(), ClientID: r.Uint32(), Port: r.Uint16()}
	for _, t := range r.Tags() {
		switch {
		case t.Name != "":
			l.Tags = append(l.Tags, t)
		case t.ID == tagName && t.Type == wire.TagString:
			l.Name = t.String
		case t.ID == tagVersion && isUint(t):
			l.Version = uint32(t.Uint)
		case t.ID == tagServerFlags && isUint(t):
			l.Flags = uint32(t.Uint)
		case t.ID == tagEmuleVersion && isUint(t):
			l.EmuleVersion = uint32(t.Uint)
		case t.ID == tagIPv6 && t.Type == wire.TagHash:
			l.IPv6 = netip.AddrFrom16(t.Hash)
		default:
			l.Tags = append(l.Tags, t)
		}
	}
	return l
}

func isUint(t wire.Tag) bool {
	return t.Type == wire.TagUint8 || t.Type == wire.TagUint16 || t.Type == wire.TagUint32
}

// IDChange is OP_IDCHANGE: the id the server gave us. Reserved is the third
// word, which servers fill inconsistently (ipv6-spec §4.2). ReportedIP is
// the server's view of our IPv4; absent when the server sends zero.
type IDChange struct {
	ClientID   uint32
	Flags      uint32
	Reserved   uint32
	ReportedIP netip.Addr
	// ObfuscationPort is the server's obfuscation TCP port; 0 when the
	// server does not send it.
	ObfuscationPort uint32
}

func (c IDChange) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opIDChange)
	b = binary.LittleEndian.AppendUint32(b, c.ClientID)
	b = binary.LittleEndian.AppendUint32(b, c.Flags)
	b = binary.LittleEndian.AppendUint32(b, c.Reserved)
	b = wire.BuildAddr(b, c.ReportedIP)
	if c.ObfuscationPort != 0 {
		b = binary.LittleEndian.AppendUint32(b, c.ObfuscationPort)
	}
	return b
}

func parseIDChange(r *wire.Reader) IDChange {
	c := IDChange{ClientID: r.Uint32()}
	if r.Len() >= 4 {
		c.Flags = r.Uint32()
	}
	if r.Len() >= 4 {
		c.Reserved = r.Uint32()
	}
	if r.Len() >= 4 {
		c.ReportedIP = r.Addr()
	}
	if r.Len() >= 4 {
		c.ObfuscationPort = r.Uint32()
	}
	return c
}

// ServerMessage is OP_SERVERMESSAGE: free text, often several lines.
type ServerMessage struct{ Text string }

func (m ServerMessage) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opServerMessage)
	return wire.BuildString(b, m.Text)
}

// ServerStatus is OP_SERVERSTATUS.
type ServerStatus struct {
	Users uint32
	Files uint32
}

func (s ServerStatus) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opServerStatus)
	return binary.LittleEndian.AppendUint32(binary.LittleEndian.AppendUint32(b, s.Users), s.Files)
}

// ServerIdent is OP_SERVERIDENT. YourIP, IPv6Status and IPv6 are the
// emule-qt IPv6 tags (ipv6-spec §4.3); IPv6Status bits say the server has,
// can be reached at and has probed an IPv6 address (0x01, 0x02, 0x04).
type ServerIdent struct {
	Hash        wire.Hash
	Addr        netip.AddrPort
	Name        string
	Description string
	YourIP      netip.Addr
	IPv6Status  byte
	IPv6        netip.Addr
	Tags        []wire.Tag
}

func (s ServerIdent) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opServerIdent)
	var tags []wire.Tag
	if s.Name != "" {
		tags = append(tags, wire.Tag{Type: wire.TagString, ID: tagName, String: s.Name})
	}
	if s.Description != "" {
		tags = append(tags, wire.Tag{Type: wire.TagString, ID: tagDescription, String: s.Description})
	}
	if s.YourIP.IsValid() {
		tags = append(tags, wire.Tag{Type: wire.TagHash, ID: tagYourIP, Hash: s.YourIP.As16()})
	}
	if s.IPv6Status != 0 {
		tags = append(tags, wire.Tag{Type: wire.TagUint8, ID: tagIPv6Status, Uint: uint64(s.IPv6Status)})
	}
	if s.IPv6.IsValid() {
		tags = append(tags, wire.Tag{Type: wire.TagHash, ID: tagServerIPv6, Hash: s.IPv6.As16()})
	}
	tags = append(tags, s.Tags...)
	b = append(b, s.Hash[:]...)
	b = wire.BuildAddrPort(b, s.Addr)
	return wire.BuildTags(b, tags)
}

func parseServerIdent(r *wire.Reader) ServerIdent {
	s := ServerIdent{Hash: r.Hash(), Addr: r.AddrPort()}
	for _, t := range r.Tags() {
		switch {
		case t.Name != "":
			s.Tags = append(s.Tags, t)
		case t.ID == tagName && t.Type == wire.TagString:
			s.Name = t.String
		case t.ID == tagDescription && t.Type == wire.TagString:
			s.Description = t.String
		case t.ID == tagYourIP && t.Type == wire.TagHash:
			s.YourIP = netip.AddrFrom16(t.Hash)
		case t.ID == tagIPv6Status && isUint(t):
			s.IPv6Status = byte(t.Uint)
		case t.ID == tagServerIPv6 && t.Type == wire.TagHash:
			s.IPv6 = netip.AddrFrom16(t.Hash)
		default:
			s.Tags = append(s.Tags, t)
		}
	}
	return s
}

// GetSources is OP_GETSOURCES. Sizes above 4 GiB are sent as a zero uint32
// followed by the uint64 size. IsObfu sends OP_GETSOURCES_OBFU, which the
// server answers with a FoundSources that IsObfu too. Inside
// GlobGetSources2 only Hash and Size travel.
type GetSources struct {
	Hash   wire.Hash
	Size   uint64
	IsObfu bool
}

func (g GetSources) Build(b []byte) []byte {
	op := opGetSources
	if g.IsObfu {
		op = opGetSourcesObfu
	}
	return buildSizedHash(append(b, wire.ProtocolEDonkey, op), g.Hash, g.Size)
}

func buildSizedHash(b []byte, hash wire.Hash, size uint64) []byte {
	b = append(b, hash[:]...)
	if size > 0xFFFFFFFF {
		b = binary.LittleEndian.AppendUint32(b, 0)
		return binary.LittleEndian.AppendUint64(b, size)
	}
	return binary.LittleEndian.AppendUint32(b, uint32(size))
}

func parseSizedHash(r *wire.Reader) (wire.Hash, uint64) {
	hash := r.Hash()
	size := uint64(r.Uint32())
	if size == 0 && r.Len() >= 8 {
		size = r.Uint64()
	}
	return hash, size
}

// Source is one entry of a source answer. CryptOptions and UserHash travel
// only in the obfuscation variants, UserHash only when CryptOptions has bit
// 0x80. A ClientID of wire.IPv6Sentinel means IPv6 follows (ipv6-spec §4.4).
type Source struct {
	ClientID     uint32
	Port         uint16
	CryptOptions byte
	UserHash     wire.Hash
	IPv6         netip.Addr
}

// FoundSources is OP_FOUNDSOURCES, or OP_FOUNDSOURCES_OBFU when IsObfu:
// then each source carries its crypt options, which obfuscated connections
// need. GlobFoundSources carries the plain form only.
type FoundSources struct {
	Hash    wire.Hash
	Sources []Source
	IsObfu  bool
}

func (f FoundSources) Build(b []byte) []byte {
	op := opFoundSources
	if f.IsObfu {
		op = opFoundSourcesObfu
	}
	return buildSources(append(b, wire.ProtocolEDonkey, op), f, f.IsObfu)
}

func buildSources(b []byte, f FoundSources, isObfu bool) []byte {
	b = append(b, f.Hash[:]...)
	b = append(b, byte(len(f.Sources)))
	for _, s := range f.Sources {
		b = binary.LittleEndian.AppendUint32(b, s.ClientID)
		b = binary.LittleEndian.AppendUint16(b, s.Port)
		if isObfu {
			b = append(b, s.CryptOptions)
			if s.CryptOptions&wire.CryptHasUserHash != 0 {
				b = append(b, s.UserHash[:]...)
			}
		}
		if s.ClientID == wire.IPv6Sentinel {
			b = wire.BuildIPv6(b, s.IPv6)
		}
	}
	return b
}

// parseSources consumes the 16 IPv6 bytes after every sentinel record; a
// reader that skipped them would misread the rest of the list.
func parseSources(r *wire.Reader, isObfu bool) FoundSources {
	f := FoundSources{Hash: r.Hash(), IsObfu: isObfu}
	count := int(r.Uint8())
	if count*6 > r.Len() {
		r.SetErr(wire.ErrShort)
		return f
	}
	f.Sources = make([]Source, 0, count)
	for range count {
		s := Source{ClientID: r.Uint32(), Port: r.Uint16()}
		if isObfu {
			s.CryptOptions = r.Uint8()
			if s.CryptOptions&wire.CryptHasUserHash != 0 {
				s.UserHash = r.Hash()
			}
		}
		if s.ClientID == wire.IPv6Sentinel {
			s.IPv6 = r.IPv6()
		}
		f.Sources = append(f.Sources, s)
	}
	return f
}

// CallbackRequest is OP_CALLBACKREQUEST: ask the server to have the LowID
// peer ClientID connect to us.
type CallbackRequest struct{ ClientID uint32 }

func (c CallbackRequest) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opCallbackRequest)
	return binary.LittleEndian.AppendUint32(b, c.ClientID)
}

// CallbackRequested is OP_CALLBACKREQUESTED: a peer asks us, through the
// server, to connect to it. Obfuscation-aware servers append the peer's
// crypt options and user hash.
type CallbackRequested struct {
	Addr         netip.AddrPort
	CryptOptions byte
	UserHash     wire.Hash
}

func (c CallbackRequested) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opCallbackRequested)
	b = wire.BuildAddrPort(b, c.Addr)
	if c.CryptOptions != 0 {
		b = append(append(b, c.CryptOptions), c.UserHash[:]...)
	}
	return b
}

func parseCallbackRequested(r *wire.Reader) CallbackRequested {
	c := CallbackRequested{Addr: r.AddrPort()}
	if r.Len() >= 17 {
		c.CryptOptions = r.Uint8()
		c.UserHash = r.Hash()
	}
	return c
}

// CallbackRequestedIPv6 is OP_CALLBACKREQUESTED_IPV6 (ipv6-spec §4.5).
type CallbackRequestedIPv6 struct{ Addr netip.AddrPort }

func (c CallbackRequestedIPv6) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opCallbackRequestedIPv6)
	return binary.LittleEndian.AppendUint16(wire.BuildIPv6(b, c.Addr.Addr()), c.Addr.Port())
}

// CallbackFailed is OP_CALLBACK_FAIL: the server could not reach the peer.
type CallbackFailed struct{}

func (CallbackFailed) Build(b []byte) []byte {
	return append(b, wire.ProtocolEDonkey, opCallbackFailed)
}

// OfferFiles is OP_OFFERFILES, publishing shared files to the server.
type OfferFiles struct{ Files []OfferedFile }

// OfferedFile names one shared file. On servers with FlagCompression,
// ClientID and Port carry the Complete or Incomplete markers instead of our
// address; otherwise they carry our HighID and port, or zero for a LowID.
type OfferedFile struct {
	Hash     wire.Hash
	ClientID uint32
	Port     uint16
	Tags     []wire.Tag
}

const (
	CompleteID     uint32 = 0xFBFBFBFB
	CompletePort   uint16 = 0xFBFB
	IncompleteID   uint32 = 0xFCFCFCFC
	IncompletePort uint16 = 0xFCFC
)

// File tag IDs used in OfferedFile.Tags.
const (
	FileName   byte = 0x01
	FileSize   byte = 0x02
	FileSizeHi byte = 0x3A
)

func (o OfferFiles) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opOfferFiles)
	b = binary.LittleEndian.AppendUint32(b, uint32(len(o.Files)))
	for _, f := range o.Files {
		b = append(b, f.Hash[:]...)
		b = binary.LittleEndian.AppendUint32(b, f.ClientID)
		b = binary.LittleEndian.AppendUint16(b, f.Port)
		b = wire.BuildTags(b, f.Tags)
	}
	return b
}

func parseOfferFiles(r *wire.Reader) OfferFiles {
	var o OfferFiles
	count := r.Uint32()
	if uint64(count) > uint64(r.Len()/26) {
		r.SetErr(wire.ErrShort)
		return o
	}
	for range count {
		o.Files = append(o.Files, OfferedFile{Hash: r.Hash(), ClientID: r.Uint32(), Port: r.Uint16(), Tags: r.Tags()})
	}
	return o
}
