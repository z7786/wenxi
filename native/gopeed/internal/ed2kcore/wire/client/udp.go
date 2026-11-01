package client

import (
	"encoding/binary"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// ReaskFilePing is the UDP OP_REASKFILEPING a queued downloader sends to keep
// its place. It carries a FileRequest's fields, keyed by the UDP version
// instead: version 4 appends the sender's part status, version 3 and up its
// complete-source count.
type ReaskFilePing FileRequest

func (p ReaskFilePing) Build(b []byte) []byte {
	return buildFileRequest(append(b, wire.ProtocolEMule, opReaskFilePing), FileRequest(p))
}

// parseReaskFilePing tells the versions apart by length: version 4 always
// carries both fields (at least four bytes), version 3 exactly two.
func parseReaskFilePing(r *wire.Reader) ReaskFilePing {
	p := ReaskFilePing{Hash: r.Hash()}
	if r.Len() > 2 {
		p.HasParts, p.Parts = true, r.Bitfield()
	}
	if r.Len() > 0 {
		p.HasCompleteSources, p.CompleteSources = true, r.Uint16()
	}
	return p
}

// ReaskAck is OP_REASKACK: our queue rank, preceded by the uploader's part
// status from UDP version 4 on.
type ReaskAck struct {
	HasParts bool
	Parts    wire.Bitfield
	Rank     uint16
}

func (a ReaskAck) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opReaskAck)
	if a.HasParts {
		b = wire.BuildBitfield(b, a.Parts)
	}
	return binary.LittleEndian.AppendUint16(b, a.Rank)
}

func parseReaskAck(r *wire.Reader) ReaskAck {
	var a ReaskAck
	if r.Len() > 2 {
		a.HasParts, a.Parts = true, r.Bitfield()
	}
	a.Rank = r.Uint16()
	return a
}

// FileNotFound is OP_FILENOTFOUND: the uploader no longer shares the file.
type FileNotFound struct{}

func (FileNotFound) Build(b []byte) []byte { return append(b, wire.ProtocolEMule, opFileNotFound) }

// QueueFull is OP_QUEUEFULL: the uploader's queue has no room for us.
type QueueFull struct{}

func (QueueFull) Build(b []byte) []byte { return append(b, wire.ProtocolEMule, opQueueFull) }
