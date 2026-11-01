package server

import (
	"encoding/binary"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// GlobGetSources is the UDP OP_GLOBGETSOURCES: source queries for several
// files by hash alone, for servers without OP_GLOBGETSOURCES2.
type GlobGetSources struct{ Files []wire.Hash }

func (g GlobGetSources) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opGlobGetSources)
	for _, h := range g.Files {
		b = append(b, h[:]...)
	}
	return b
}

func parseGlobGetSources(r *wire.Reader) GlobGetSources {
	var g GlobGetSources
	for r.Len() > 0 && r.Err() == nil {
		g.Files = append(g.Files, r.Hash())
	}
	return g
}

// GlobGetSources2 is the UDP OP_GLOBGETSOURCES2: source queries for several
// files, each with its size.
type GlobGetSources2 struct{ Files []GetSources }

func (g GlobGetSources2) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opGlobGetSources2)
	for _, f := range g.Files {
		b = buildSizedHash(b, f.Hash, f.Size)
	}
	return b
}

func parseGlobGetSources2(r *wire.Reader) GlobGetSources2 {
	var g GlobGetSources2
	for r.Len() > 0 && r.Err() == nil {
		hash, size := parseSizedHash(r)
		g.Files = append(g.Files, GetSources{Hash: hash, Size: size})
	}
	return g
}

// GlobFoundSources is the UDP OP_GLOBFOUNDSOURCES. One datagram may chain
// several files; each after the first is preceded by 0xE3 0x9B again.
type GlobFoundSources struct{ Files []FoundSources }

func (g GlobFoundSources) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opGlobFoundSources)
	for i, f := range g.Files {
		if i > 0 {
			b = append(b, wire.ProtocolEDonkey, opGlobFoundSources)
		}
		b = buildSources(b, f, false)
	}
	return b
}

func parseGlobFoundSources(r *wire.Reader) GlobFoundSources {
	var g GlobFoundSources
	for {
		g.Files = append(g.Files, parseSources(r, false))
		if r.Err() != nil || r.Len() < 2 || r.Rest[0] != wire.ProtocolEDonkey || r.Rest[1] != opGlobFoundSources {
			return g
		}
		r.Bytes(2)
	}
}

// GlobServStatReq is the UDP OP_GLOBSERVSTATREQ; the server echoes
// Challenge.
type GlobServStatReq struct{ Challenge uint32 }

func (g GlobServStatReq) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opGlobServStatReq)
	return binary.LittleEndian.AppendUint32(b, g.Challenge)
}

// Server UDP flags (GlobServStatRes.UDPFlags).
const (
	UDPFlagGetSources     uint32 = 0x0001
	UDPFlagNewTags        uint32 = 0x0008
	UDPFlagUnicode        uint32 = 0x0010
	UDPFlagGetSources2    uint32 = 0x0020
	UDPFlagLargeFiles     uint32 = 0x0100
	UDPFlagUDPObfuscation uint32 = 0x0200
	UDPFlagTCPObfuscation uint32 = 0x0400
)

// ObfuscatedPing is aMule's obfuscated status ping (ServerList.cpp:297-322),
// sent to the server's TCP port plus 12: a bare challenge and padding, with
// no protocol byte or opcode. The server answers OP_GLOBSERVSTATRES
// obfuscated with the challenge as key.
type ObfuscatedPing struct {
	Challenge uint32
	Padding   []byte
}

func (p ObfuscatedPing) Build(b []byte) []byte {
	return append(binary.LittleEndian.AppendUint32(b, p.Challenge), p.Padding...)
}

// GlobServStatRes is the UDP OP_GLOBSERVSTATRES. Older servers stop after
// any field from MaxUsers on; missing fields decode as zero.
type GlobServStatRes struct {
	Challenge          uint32
	Users              uint32
	Files              uint32
	MaxUsers           uint32
	SoftFiles          uint32
	HardFiles          uint32
	UDPFlags           uint32
	LowIDUsers         uint32
	UDPObfuscationPort uint16
	TCPObfuscationPort uint16
	UDPKey             uint32
}

func (g GlobServStatRes) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opGlobServStatRes)
	for _, v := range []uint32{g.Challenge, g.Users, g.Files, g.MaxUsers, g.SoftFiles, g.HardFiles, g.UDPFlags, g.LowIDUsers} {
		b = binary.LittleEndian.AppendUint32(b, v)
	}
	b = binary.LittleEndian.AppendUint16(b, g.UDPObfuscationPort)
	b = binary.LittleEndian.AppendUint16(b, g.TCPObfuscationPort)
	return binary.LittleEndian.AppendUint32(b, g.UDPKey)
}

func parseGlobServStatRes(r *wire.Reader) GlobServStatRes {
	g := GlobServStatRes{Challenge: r.Uint32(), Users: r.Uint32(), Files: r.Uint32()}
	for _, field := range []*uint32{&g.MaxUsers, &g.SoftFiles, &g.HardFiles, &g.UDPFlags, &g.LowIDUsers} {
		if r.Len() < 4 {
			return g
		}
		*field = r.Uint32()
	}
	if r.Len() < 4 {
		return g
	}
	g.UDPObfuscationPort = r.Uint16()
	g.TCPObfuscationPort = r.Uint16()
	if r.Len() >= 4 {
		g.UDPKey = r.Uint32()
	}
	return g
}
