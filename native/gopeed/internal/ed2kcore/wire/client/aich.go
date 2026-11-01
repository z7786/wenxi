package client

import (
	"encoding/binary"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// AICHFileHashRequest is OP_AICHFILEHASHREQ: "tell me the file's AICH root".
// Inside a MultiPacket it is the bare opcode.
type AICHFileHashRequest struct{ Hash wire.Hash }

func (a AICHFileHashRequest) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opAICHFileHashRequest)
	return append(b, a.Hash[:]...)
}

// AICHFileHashAnswer is OP_AICHFILEHASHANS. Inside a MultiPacketAnswer only
// the root follows the opcode.
type AICHFileHashAnswer struct {
	Hash wire.Hash
	Root wire.AICHHash
}

func (a AICHFileHashAnswer) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opAICHFileHashAnswer)
	return append(append(b, a.Hash[:]...), a.Root[:]...)
}

// AICHRequest is OP_AICHREQUEST: the recovery data of one part, for the root
// the asker trusts.
type AICHRequest struct {
	Hash wire.Hash
	Part uint16
	Root wire.AICHHash
}

func (a AICHRequest) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opAICHRequest)
	b = binary.LittleEndian.AppendUint16(append(b, a.Hash[:]...), a.Part)
	return append(b, a.Root[:]...)
}

// AICHEntry is one node of an AICH hash tree. Ident is its path from the
// root: a leading 1 for the root, then 1 for each left and 0 for each right
// step (aMule SHAHashSet.h:47-66).
type AICHEntry struct {
	Ident uint32
	Hash  wire.AICHHash
}

// AICHAnswer is OP_AICHANSWER. Without HasData the sender cannot help.
// Entries travel with 16-bit idents unless HasLongIdents, which aMule uses
// for files above 4 GB (SHAHashSet.cpp:493-525).
type AICHAnswer struct {
	Hash          wire.Hash
	HasData       bool
	Part          uint16
	Root          wire.AICHHash
	Entries       []AICHEntry
	HasLongIdents bool
}

func (a AICHAnswer) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opAICHAnswer)
	b = append(b, a.Hash[:]...)
	if !a.HasData {
		return b
	}
	b = binary.LittleEndian.AppendUint16(b, a.Part)
	b = append(b, a.Root[:]...)
	if a.HasLongIdents {
		b = binary.LittleEndian.AppendUint16(b, 0)
	}
	b = binary.LittleEndian.AppendUint16(b, uint16(len(a.Entries)))
	for _, e := range a.Entries {
		if a.HasLongIdents {
			b = binary.LittleEndian.AppendUint32(b, e.Ident)
		} else {
			b = binary.LittleEndian.AppendUint16(b, uint16(e.Ident))
		}
		b = append(b, e.Hash[:]...)
	}
	if !a.HasLongIdents {
		b = binary.LittleEndian.AppendUint16(b, 0)
	}
	return b
}

// parseAICHAnswer reads the 32-bit list only when the 16-bit one is empty,
// as aMule's ReadRecoveryData does (SHAHashSet.cpp:567).
func parseAICHAnswer(r *wire.Reader) AICHAnswer {
	a := AICHAnswer{Hash: r.Hash()}
	if r.Len() == 0 {
		return a
	}
	a.HasData = true
	a.Part = r.Uint16()
	a.Root = r.AICHHash()
	a.Entries = parseAICHEntries(r, 2)
	if len(a.Entries) == 0 && r.Len() >= 2 {
		a.HasLongIdents = true
		a.Entries = parseAICHEntries(r, 4)
	}
	r.Rest = nil
	return a
}

func parseAICHEntries(r *wire.Reader, identSize int) []AICHEntry {
	count := int(r.Uint16())
	if count*(identSize+len(wire.AICHHash{})) > r.Len() {
		r.SetErr(wire.ErrShort)
		return nil
	}
	var entries []AICHEntry
	for range count {
		var e AICHEntry
		if identSize == 2 {
			e.Ident = uint32(r.Uint16())
		} else {
			e.Ident = r.Uint32()
		}
		e.Hash = r.AICHHash()
		entries = append(entries, e)
	}
	return entries
}
