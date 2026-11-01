package kad

import (
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
)

// eMule opcodes.h.
const (
	republishSources = 5 * time.Hour // KADEMLIAREPUBLISHTIMES: also how long a stored source lives
	maxSourcesByFile = 1000          // KADEMLIAMAXSOUCEPERFILE
	// maxIndexed bounds the sources stored over all files. aMule bounds
	// only each file, so a node publishing to many file IDs near ours fills
	// it without end; KADEMLIAMAXINDEX, its keyword index size, serves here.
	maxIndexed = 50000
	// One SearchRes carries at most this many entries, keeping it well
	// under the UDP size eMule reads.
	entriesByPacket = 50
	// TAG_PUBLISHINFO and TAG_KADAICHHASHRESULT belong in answers the
	// storing node builds itself; aMule 3.1.0 never stores a publisher's
	// (Entry.cpp:80-91).
	tagPublishInfo       byte = 0x33
	tagKadAICHHashResult byte = 0x37
)

type indexed struct {
	tags    []wire.Tag
	expires time.Time
}

// index stores the sources other nodes publish to us, as every Kad node
// near a file's hash is expected to.
type index struct {
	files map[wire.Hash]map[wire.Hash]indexed
	count int
}

// onPublishSources stores a source and returns whether it was accepted.
// Like eMule's Process_KADEMLIA2_PUBLISH_SOURCE_REQ it records the sender's
// IP and UDP port and refuses files too far from our ID.
func (x *index) onPublishSources(self wire.Hash, from netip.AddrPort, req kadwire.PublishSourcesReq, now time.Time) (load byte, isStored bool) {
	if !matchTolerance(distance(self, req.FileID)) {
		return 0, false
	}
	if _, ok := tagByID(req.Source.Tags, kadwire.TagSourceType); !ok {
		return 0, false
	}
	sources := x.files[req.FileID]
	_, isKnown := sources[req.Source.ID]
	if !isKnown && (len(sources) >= maxSourcesByFile || x.count >= maxIndexed) {
		return 0, false
	}
	if sources == nil {
		sources = map[wire.Hash]indexed{}
		x.files[req.FileID] = sources
	}
	if !isKnown {
		x.count++
	}
	tags := []wire.Tag{{Type: wire.TagUint32, ID: kadwire.TagSourceIP, Uint: uint64(kadwire.ToUint32(from.Addr()))}}
	hasUDPPort := false
	for _, t := range req.Source.Tags {
		if t.Name == "" && (t.ID == kadwire.TagSourceIP || t.ID == tagPublishInfo || t.ID == tagKadAICHHashResult) {
			continue
		}
		hasUDPPort = hasUDPPort || (t.Name == "" && t.ID == kadwire.TagSourceUPort && t.Uint != 0)
		tags = append(tags, t)
	}
	if !hasUDPPort {
		tags = append(tags, wire.Tag{Type: wire.TagUint16, ID: kadwire.TagSourceUPort, Uint: uint64(from.Port())})
	}
	sources[req.Source.ID] = indexed{tags: tags, expires: now.Add(republishSources)}
	return byte(len(sources) * 100 / maxSourcesByFile), true
}

// buildResults splits the live sources of a file into SearchRes packets.
func (x *index) buildResults(self, target wire.Hash, now time.Time) []kadwire.SearchRes {
	var entries []kadwire.Entry
	for id, s := range x.files[target] {
		if now.Before(s.expires) && len(entries) < fileTotal {
			entries = append(entries, kadwire.Entry{ID: id, Tags: s.tags})
		}
	}
	var out []kadwire.SearchRes
	for chunk := range slices.Chunk(entries, entriesByPacket) {
		out = append(out, kadwire.SearchRes{Source: self, Target: target, Results: chunk})
	}
	return out
}

func (x *index) clearExpired(now time.Time) {
	for file, sources := range x.files {
		for id, s := range sources {
			if !now.Before(s.expires) {
				delete(sources, id)
				x.count--
			}
		}
		if len(sources) == 0 {
			delete(x.files, file)
		}
	}
}
