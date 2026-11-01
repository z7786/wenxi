// Derived from goed2k protocol/client/source_exchange.go.
package client

import (
	"encoding/binary"
	"fmt"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// Source is one peer in a Source Exchange answer. Which fields travel
// depends on the answer's form; fields a form cannot carry are left zero on
// decode and ignored on encode.
type Source struct {
	ClientID     uint32
	Port         uint16
	Server       netip.AddrPort
	UserHash     wire.Hash
	CryptOptions byte
	IPv6         netip.Addr
}

// requestSources is OP_REQUESTSOURCES (Source Exchange v1), which Kelpie
// neither sends nor answers. It is parsed so that the requests after it in
// a MultiPacket are not lost to a trailing wire.Unknown.
type requestSources struct{ Hash wire.Hash }

func (s requestSources) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opRequestSources)
	return append(b, s.Hash[:]...)
}

// RequestSources2 is OP_REQUESTSOURCES2.
type RequestSources2 struct {
	Version byte
	Options uint16
	Hash    wire.Hash
}

func (s RequestSources2) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opRequestSources2)
	b = binary.LittleEndian.AppendUint16(append(b, s.Version), s.Options)
	return append(b, s.Hash[:]...)
}

const (
	// SourceExchange2Version is the classic SX2 version eMule speaks.
	SourceExchange2Version = 4
	// ExtendedSourcesVersion selects the tagged record of emule-qt's
	// Extended Source Exchange (ipv6-spec §3.3), the only SX2 form that
	// carries IPv6. Kelpie asks for version 1 only from peers advertising
	// ModMiscExtendedSources, so a version-1 answer is always tagged.
	ExtendedSourcesVersion = 1
)

// AnswerSources2 is OP_ANSWERSOURCES2. Version picks the record layout:
// ExtendedSourcesVersion for tagged records, otherwise classic records with
// the user hash from version 2 and crypt options from version 4.
type AnswerSources2 struct {
	Version byte
	Hash    wire.Hash
	Sources []Source
}

// Extended Source Exchange record tags (ipv6-spec §3.3.3).
const (
	tagSourceServerIP     byte = 0xBA
	tagSourceServerPort   byte = 0xBB
	tagSourceUserHash     byte = 0xBC
	tagSourceCryptOptions byte = 0xBE
)

func (a AnswerSources2) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opAnswerSources2)
	b = append(b, a.Version)
	b = append(b, a.Hash[:]...)
	b = binary.LittleEndian.AppendUint16(b, uint16(len(a.Sources)))
	for _, s := range a.Sources {
		if a.Version == ExtendedSourcesVersion {
			b = buildExtendedSource(b, s)
			continue
		}
		b = buildClassicSource(b, s)
		if a.Version >= 2 {
			b = append(b, s.UserHash[:]...)
		}
		if a.Version >= 4 {
			b = append(b, s.CryptOptions)
		}
	}
	return b
}

func parseAnswerSources2(r *wire.Reader) AnswerSources2 {
	a := AnswerSources2{Version: r.Uint8(), Hash: r.Hash()}
	count := int(r.Uint16())
	if a.Version == ExtendedSourcesVersion {
		// Tagged records have no fixed size; each needs at least seven bytes.
		if count*7 > r.Len() {
			r.SetErr(fmt.Errorf("client: %d sources cannot fit in %d bytes", count, r.Len()))
			return a
		}
		for range count {
			a.Sources = append(a.Sources, parseExtendedSource(r))
		}
		return a
	}
	size := 12
	if a.Version >= 2 {
		size += 16
	}
	if a.Version >= 4 {
		size++
	}
	if count*size != r.Len() {
		r.SetErr(fmt.Errorf("client: %d v%d sources cannot fill %d bytes", count, a.Version, r.Len()))
		return a
	}
	a.Sources = make([]Source, count)
	for i := range a.Sources {
		a.Sources[i] = parseClassicSource(r)
		if a.Version >= 2 {
			a.Sources[i].UserHash = r.Hash()
		}
		if a.Version >= 4 {
			a.Sources[i].CryptOptions = r.Uint8()
		}
	}
	return a
}

func buildClassicSource(b []byte, s Source) []byte {
	b = binary.LittleEndian.AppendUint32(b, s.ClientID)
	b = binary.LittleEndian.AppendUint16(b, s.Port)
	return wire.BuildAddrPort(b, s.Server)
}

func parseClassicSource(r *wire.Reader) Source {
	return Source{ClientID: r.Uint32(), Port: r.Uint16(), Server: r.AddrPort()}
}

// buildExtendedSource sends whatever the Source holds. Withholding the user
// hash and crypt options from peers without ModMiscExtendedSourcesSkipTags
// is the caller's decision (ipv6-spec §3.3.6).
func buildExtendedSource(b []byte, s Source) []byte {
	var tags []wire.Tag
	if s.Server.IsValid() {
		tags = append(tags,
			wire.Tag{Type: wire.TagUint32, ID: tagSourceServerIP, Uint: uint64(wire.ToClientID(s.Server.Addr()))},
			wire.Tag{Type: wire.TagUint16, ID: tagSourceServerPort, Uint: uint64(s.Server.Port())})
	}
	if s.IPv6.IsValid() {
		tags = append(tags, wire.Tag{Type: wire.TagHash, ID: tagIPv6, Hash: s.IPv6.As16()})
	}
	if s.UserHash != (wire.Hash{}) {
		tags = append(tags, wire.Tag{Type: wire.TagHash, ID: tagSourceUserHash, Hash: s.UserHash})
	}
	if s.CryptOptions != 0 {
		tags = append(tags, wire.Tag{Type: wire.TagUint8, ID: tagSourceCryptOptions, Uint: uint64(s.CryptOptions)})
	}
	b = binary.LittleEndian.AppendUint32(b, s.ClientID)
	b = binary.LittleEndian.AppendUint16(b, s.Port)
	b = append(b, byte(len(tags)))
	for _, t := range tags {
		b = wire.BuildCompactTag(b, t)
	}
	return b
}

func parseExtendedSource(r *wire.Reader) Source {
	s := Source{ClientID: r.Uint32(), Port: r.Uint16()}
	var serverIP uint32
	var serverPort uint16
	for range r.Uint8() {
		t := r.Tag()
		isUint := t.Type == wire.TagUint8 || t.Type == wire.TagUint16 || t.Type == wire.TagUint32
		switch {
		case t.Name != "":
		case t.ID == tagSourceServerIP && isUint:
			serverIP = uint32(t.Uint)
		case t.ID == tagSourceServerPort && isUint:
			serverPort = uint16(t.Uint)
		case t.ID == tagIPv6 && t.Type == wire.TagHash:
			s.IPv6 = netip.AddrFrom16(t.Hash)
		case t.ID == tagSourceUserHash && t.Type == wire.TagHash:
			s.UserHash = t.Hash
		case t.ID == tagSourceCryptOptions && isUint:
			s.CryptOptions = byte(t.Uint)
		}
	}
	if serverIP != 0 {
		s.Server = netip.AddrPortFrom(wire.ToAddr(serverIP), serverPort)
	}
	return s
}
