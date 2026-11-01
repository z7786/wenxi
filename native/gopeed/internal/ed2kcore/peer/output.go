package peer

import (
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// Output is what the engine must do after a call: write Send to the
// connection in order, handle Events, then close the connection if Close,
// the reason, is set.
type Output struct {
	Send   []wire.Packet
	Events []Event
	Close  string
}

func (o *Output) send(p ...wire.Packet) { o.Send = append(o.Send, p...) }
func (o *Output) add(e Event)           { o.Events = append(o.Events, e) }

const (
	closeTimeout  = "timeout"
	closeProtocol = "protocol violation"
)

type Event interface{ isEvent() }

// HandshakeCompleted: both hellos are exchanged and Capabilities is final.
// YourIP is the address the peer sees us at, a vote rather than a fact.
type HandshakeCompleted struct{ YourIP netip.Addr }

// Identified: the peer proved it holds PublicKey. The engine checks the key
// against the one it stored for the peer's user hash, if any.
type Identified struct{ PublicKey []byte }

// StatusReceived carries which parts of File the peer has.
type StatusReceived struct {
	File  wire.Hash
	Parts piece.Set
}

// HashSetReceived carries part hashes already checked against File.
type HashSetReceived struct {
	File   wire.Hash
	Hashes []wire.Hash
}

// FileRejected: the peer does not share File; the session forgot it.
type FileRejected struct{ File wire.Hash }

// Queued: the peer put us in its upload queue for File at Rank. Rank is 0
// when it ended our slot without telling a rank, or the session gave the slot
// up after DOWNLOADTIMEOUT; every block in flight for File is dropped then.
// aMule reads OP_OUTOFPARTREQS as a return to the queue
// (ClientTCPSocket.cpp:693-700).
type Queued struct {
	File wire.Hash
	Rank uint32
}

// SlotAsked: we asked the peer for an upload slot for File.
type SlotAsked struct{ File wire.Hash }

// SlotGranted: the peer accepted our upload request. File is zero when the
// grant arrives before any file started on this connection, typically on a
// connection the peer opened to us; the engine then Adds the file it queued
// for with this user.
type SlotGranted struct{ File wire.Hash }

// NoNeededParts: the peer has no part of File we still need, or its slot
// gave nothing to request, so no slot is asked for or kept (aMule
// DS_NONEEDEDPARTS).
type NoNeededParts struct{ File wire.Hash }

// BlocksWanted asks the engine to Request up to Count blocks of File.
type BlocksWanted struct {
	File  wire.Hash
	Count int
}

// BlockReceived hands over the Data of Block. Payload is the packet data
// that carried it, compressed or not, which credits count as aMule does
// (DownloadClient.cpp:865) and as our uploads are counted.
type BlockReceived struct {
	File    wire.Hash
	Block   piece.Block
	Data    []byte
	Payload int64
}

// UploadRequested: the peer wants to join our upload queue for File. Parts
// is what its file request said it has of File; nil when it did not say.
type UploadRequested struct {
	File  wire.Hash
	Parts piece.Set
}

// BlocksRequested asks the engine to read Blocks, all within parts of File we
// have, and SendBlock each one.
type BlocksRequested struct {
	File   wire.Hash
	Blocks []piece.Block
}

// UploadCancelled: the peer no longer wants anything uploaded.
type UploadCancelled struct{}

type SourcesFound struct {
	File    wire.Hash
	Sources []Source
}

func (HandshakeCompleted) isEvent() {}
func (Identified) isEvent()         {}
func (StatusReceived) isEvent()     {}
func (HashSetReceived) isEvent()    {}
func (FileRejected) isEvent()       {}
func (Queued) isEvent()             {}
func (SlotAsked) isEvent()          {}
func (SlotGranted) isEvent()        {}
func (NoNeededParts) isEvent()      {}
func (BlocksWanted) isEvent()       {}
func (BlockReceived) isEvent()      {}
func (UploadRequested) isEvent()    {}
func (BlocksRequested) isEvent()    {}
func (UploadCancelled) isEvent()    {}
func (SourcesFound) isEvent()       {}
