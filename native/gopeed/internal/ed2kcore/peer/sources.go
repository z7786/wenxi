package peer

import (
	"encoding/binary"
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

const (
	// SOURCECLIENTREASKS: eMule asks one client for sources, and answers its
	// requests, at most this often. The per-file SOURCECLIENTREASKF and the
	// rarity rules belong to the transfer.
	sourceInterval = 40 * time.Minute
	// CPartFile::CreateSrcInfoPacket stops at 500 sources; an answer is
	// read no further, as aMule stops adding at its per-file cap
	// (PartFile.cpp:3040).
	maxSources = 500
)

// Source is another peer that has a file. A HighID source has IPv4; a LowID
// source has LowID and is reached through its Server; IPv6 travels only in
// Extended Source Exchange (emule-qt ipv6-spec §3.3).
type Source struct {
	IPv4     netip.Addr
	IPv6     netip.Addr
	Port     uint16
	LowID    uint32
	Server   netip.AddrPort
	UserHash wire.Hash
	// CryptOptions is the source's obfuscation setting, laid out as in
	// Source Exchange v4, the servers' answers, Kad and the Hello:
	// wire.CryptSupported, wire.CryptRequested, wire.CryptRequired.
	CryptOptions byte
}

type sourceState struct {
	lastRequest time.Time
	lastAnswer  time.Time
	asked       map[wire.Hash]bool
}

// RequestSources asks the peer for other sources of an added file, if it
// speaks Source Exchange v2 and we have not asked it within
// SOURCECLIENTREASKS; otherwise it does nothing.
func (s *Session) RequestSources(file wire.Hash, now time.Time) Output {
	var out Output
	d := s.downloadByHash(file)
	if s.greeting != handshaken || !s.caps.HasSourceExchange2 || d == nil ||
		!s.sx.lastRequest.IsZero() && now.Sub(s.sx.lastRequest) < sourceInterval {
		return out
	}
	version := byte(client.SourceExchange2Version)
	if s.features.hasExtendedSources {
		version = client.ExtendedSourcesVersion
	}
	s.sx.lastRequest = now
	s.sx.asked[file] = true
	request := client.RequestSources2{Version: version, Hash: file}
	// aMule 2.3 closes the connection on a standalone OP_REQUESTSOURCES2
	// (it checks the body for the 16 bytes of the old OP_REQUESTSOURCES);
	// inside a multipacket, where eMule puts it too, it is read right.
	s.sendMultiPacket(file, d.size, []wire.Packet{request}, &out)
	return out
}

// onSourcesRequest answers a source request for a file we offer, at most
// once per SOURCECLIENTREASKS.
func (s *Session) onSourcesRequest(p client.RequestSources2, now time.Time, out *Output) {
	if _, ok := s.cfg.ShareByHash(p.Hash); !ok {
		return
	}
	if !s.sx.lastAnswer.IsZero() && now.Sub(s.sx.lastAnswer) < sourceInterval {
		return
	}
	s.sx.lastAnswer = now
	version := p.Version
	isExtended := version == client.ExtendedSourcesVersion && s.features.hasExtendedSources
	if !isExtended {
		version = min(version, client.SourceExchange2Version)
	}
	answer := client.AnswerSources2{Version: version, Hash: p.Hash}
	for _, src := range s.cfg.SourcesByHash(p.Hash, s.up.parts[p.Hash]) {
		if len(answer.Sources) == maxSources {
			break
		}
		if isExtended {
			answer.Sources = append(answer.Sources, s.toExtendedSource(src))
		} else if record, ok := toClassicSource(src, version); ok {
			answer.Sources = append(answer.Sources, record)
		}
	}
	if len(answer.Sources) > 0 {
		out.send(answer)
	}
}

func (s *Session) onSourcesAnswer(p client.AnswerSources2, out *Output) {
	if !s.sx.asked[p.Hash] {
		return
	}
	delete(s.sx.asked, p.Hash)
	var sources []Source
	for _, record := range p.Sources {
		if len(sources) == maxSources {
			break
		}
		src := toSource(record, p.Version)
		if src.Port != 0 && (src.IPv4.IsValid() || src.IPv6.IsValid() || src.LowID != 0) {
			sources = append(sources, src)
		}
	}
	if len(sources) > 0 {
		out.add(SourcesFound{File: p.Hash, Sources: sources})
	}
}

// Client ids in Source Exchange: version 1 and 2 records and Extended
// records carry the ED2K id, where a HighID is the IPv4 address read
// little-endian; from version 3 eMule sends the "hybrid" id, the address
// read big-endian, so that an address ending in .0 is not mistaken for a
// LowID. LowIDs are the same in both.
func toSource(record client.Source, version byte) Source {
	src := Source{Port: record.Port, Server: record.Server, UserHash: record.UserHash, CryptOptions: record.CryptOptions}
	if record.IPv6.Is6() && !record.IPv6.Is4In6() {
		src.IPv6 = record.IPv6
	}
	id := record.ClientID
	switch {
	case id == wire.IPv6Sentinel && version == client.ExtendedSourcesVersion:
	case wire.IsLowID(id):
		src.LowID = id
	case version >= 3:
		var a [4]byte
		binary.BigEndian.PutUint32(a[:], id)
		src.IPv4 = netip.AddrFrom4(a)
	default:
		src.IPv4 = wire.ToAddr(id)
	}
	return src
}

func toClassicSource(src Source, version byte) (client.Source, bool) {
	record := client.Source{Port: src.Port, Server: src.Server, UserHash: src.UserHash, CryptOptions: src.CryptOptions}
	switch {
	case src.IPv4.IsValid() && version >= 3:
		a := src.IPv4.As4()
		record.ClientID = binary.BigEndian.Uint32(a[:])
	case src.IPv4.IsValid():
		record.ClientID = wire.ToClientID(src.IPv4)
	case src.LowID != 0:
		record.ClientID = src.LowID
	default:
		return record, false
	}
	return record, true
}

// toExtendedSource withholds the user hash and crypt options from peers that cannot skip
// tags they do not know (ipv6-spec §3.3.6).
func (s *Session) toExtendedSource(src Source) client.Source {
	record := client.Source{Port: src.Port, Server: src.Server, IPv6: src.IPv6}
	switch {
	case src.IPv4.IsValid():
		record.ClientID = wire.ToClientID(src.IPv4)
	case src.LowID != 0:
		record.ClientID = src.LowID
	default:
		record.ClientID = wire.IPv6Sentinel
	}
	if s.features.hasExtendedSourcesSkipTags {
		record.UserHash, record.CryptOptions = src.UserHash, src.CryptOptions
	}
	return record
}
