// Derived from goed2k protocol/client (file_request.go, file_answer.go,
// file_status_*.go, hash_set_*.go, queue_rank*.go, request_parts.go,
// sending_part.go, compressed_part.go).
package client

import (
	"encoding/binary"
	"fmt"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// ExtendedRequestsVersion is the extended-requests version Kelpie must
// advertise in MiscOptions1. A peer appends file-request extensions sized by
// the version *we* advertise, and inside a MultiPacket nothing delimits them,
// so the parser can only follow this value.
const ExtendedRequestsVersion = 2

// FileRequest is OP_REQUESTFILENAME. With extended requests v1 the sender
// appends its own part status; v2 also appends its complete-source count.
type FileRequest struct {
	Hash               wire.Hash
	HasParts           bool
	Parts              wire.Bitfield
	HasCompleteSources bool
	CompleteSources    uint16
}

func (f FileRequest) Build(b []byte) []byte {
	return buildFileRequest(append(b, wire.ProtocolEDonkey, opRequestFileName), f)
}

func buildFileRequest(b []byte, f FileRequest) []byte {
	return buildFileRequestExtension(append(b, f.Hash[:]...), f)
}

func buildFileRequestExtension(b []byte, f FileRequest) []byte {
	if f.HasParts {
		b = wire.BuildBitfield(b, f.Parts)
	}
	if f.HasCompleteSources {
		b = binary.LittleEndian.AppendUint16(b, f.CompleteSources)
	}
	return b
}

func parseFileRequest(r *wire.Reader) FileRequest {
	f := FileRequest{Hash: r.Hash()}
	if r.Len() > 0 {
		f.HasParts, f.Parts = true, r.Bitfield()
	}
	if r.Len() > 0 {
		f.HasCompleteSources, f.CompleteSources = true, r.Uint16()
	}
	return f
}

// FileNameAnswer is OP_REQFILENAMEANSWER.
type FileNameAnswer struct {
	Hash wire.Hash
	Name string
}

func (f FileNameAnswer) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opFileNameAnswer)
	return wire.BuildString(append(b, f.Hash[:]...), f.Name)
}

// SetRequestFileID is OP_SETREQFILEID: "tell me your part status".
type SetRequestFileID struct{ Hash wire.Hash }

func (s SetRequestFileID) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opSetRequestFileID)
	return append(b, s.Hash[:]...)
}

// FileStatus is OP_FILESTATUS. Zero parts means the sender has the whole
// file.
type FileStatus struct {
	Hash  wire.Hash
	Parts wire.Bitfield
}

func (f FileStatus) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opFileStatus)
	return wire.BuildBitfield(append(b, f.Hash[:]...), f.Parts)
}

// NoFile is OP_FILEREQANSNOFIL: the peer does not share the file.
type NoFile struct{ Hash wire.Hash }

func (n NoFile) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opNoFile)
	return append(b, n.Hash[:]...)
}

// HashSetRequest is OP_HASHSETREQUEST.
type HashSetRequest struct{ Hash wire.Hash }

func (h HashSetRequest) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opHashSetRequest)
	return append(b, h.Hash[:]...)
}

// HashSetAnswer is OP_HASHSETANSWER: the MD4 of every part.
type HashSetAnswer struct {
	Hash  wire.Hash
	Parts []wire.Hash
}

func (h HashSetAnswer) Build(b []byte) []byte {
	return buildHashSet(append(b, wire.ProtocolEDonkey, opHashSetAnswer), h.Hash, h.Parts)
}

func buildHashSet(b []byte, hash wire.Hash, parts []wire.Hash) []byte {
	b = append(b, hash[:]...)
	b = binary.LittleEndian.AppendUint16(b, uint16(len(parts)))
	for _, p := range parts {
		b = append(b, p[:]...)
	}
	return b
}

func parseHashSetAnswer(r *wire.Reader) HashSetAnswer {
	h := HashSetAnswer{Hash: r.Hash()}
	count := int(r.Uint16())
	if count*16 > r.Len() {
		r.SetErr(wire.ErrShort)
		return h
	}
	h.Parts = make([]wire.Hash, count)
	for i := range h.Parts {
		h.Parts[i] = r.Hash()
	}
	return h
}

// HashSetRequest2 is OP_HASHSETREQUEST2, which eMule sends instead of
// HashSetRequest to peers with HasFileIdentifiers
// (DownloadClient.cpp:2485-2515).
type HashSetRequest2 struct {
	File         FileIdentifier
	IsMD4Wanted  bool
	IsAICHWanted bool
}

// HashSetAnswer2 is OP_HASHSETANSWER2 carrying the MD4 part hashes, or
// nothing when Parts is empty. Kelpie never sends the AICH part hashes; eMule
// then asks another peer (DownloadClient.cpp:836-840).
type HashSetAnswer2 struct {
	File  FileIdentifier
	Parts []wire.Hash
}

const (
	hashSetMD4  byte = 0x01
	hashSetAICH byte = 0x02
)

func (h HashSetRequest2) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opHashSetRequest2)
	var options byte
	if h.IsMD4Wanted {
		options |= hashSetMD4
	}
	if h.IsAICHWanted {
		options |= hashSetAICH
	}
	return append(buildFileIdentifier(b, h.File), options)
}

func parseHashSetRequest2(r *wire.Reader) HashSetRequest2 {
	h := HashSetRequest2{File: parseFileIdentifier(r)}
	options := r.Uint8()
	h.IsMD4Wanted, h.IsAICHWanted = options&hashSetMD4 != 0, options&hashSetAICH != 0
	return h
}

// Build lays out eMule's WriteHashSetsToPacket (FileIdentifier.cpp:267-308):
// the options byte says which sets follow.
func (h HashSetAnswer2) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opHashSetAnswer2)
	b = buildFileIdentifier(b, h.File)
	if len(h.Parts) == 0 {
		return append(b, 0)
	}
	return buildHashSet(append(b, hashSetMD4), h.File.Hash, h.Parts)
}

// StartUploadRequest is OP_STARTUPLOADREQ. Old clients send it without a
// hash, which decodes as the zero hash.
type StartUploadRequest struct{ Hash wire.Hash }

func (s StartUploadRequest) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opStartUploadRequest)
	return append(b, s.Hash[:]...)
}

// AcceptUploadRequest is OP_ACCEPTUPLOADREQ: we got an upload slot.
type AcceptUploadRequest struct{}

func (AcceptUploadRequest) Build(b []byte) []byte {
	return append(b, wire.ProtocolEDonkey, opAcceptUploadRequest)
}

// CancelTransfer is OP_CANCELTRANSFER.
type CancelTransfer struct{}

func (CancelTransfer) Build(b []byte) []byte {
	return append(b, wire.ProtocolEDonkey, opCancelTransfer)
}

// OutOfParts is OP_OUTOFPARTREQS: the uploader ends our slot.
type OutOfParts struct{}

func (OutOfParts) Build(b []byte) []byte { return append(b, wire.ProtocolEDonkey, opOutOfParts) }

// QueueRank is the eDonkey OP_QUEUERANK.
type QueueRank struct{ Rank uint32 }

func (q QueueRank) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opQueueRank)
	return binary.LittleEndian.AppendUint32(b, q.Rank)
}

// QueueRanking is the eMule OP_QUEUERANKING: a uint16 rank padded with ten
// zero bytes.
type QueueRanking struct{ Rank uint16 }

func (q QueueRanking) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opQueueRanking)
	b = binary.LittleEndian.AppendUint16(b, q.Rank)
	return append(b, make([]byte, 10)...)
}

// RequestParts is OP_REQUESTPARTS: up to three [Start, End) ranges; unused
// slots are zero. IsLarge sends OP_REQUESTPARTS_I64, which a file over 4 GiB
// needs, with 64-bit offsets.
type RequestParts struct {
	Hash    wire.Hash
	Starts  [3]uint64
	Ends    [3]uint64
	IsLarge bool
}

func (p RequestParts) Build(b []byte) []byte {
	if p.IsLarge {
		b = append(b, wire.ProtocolEMule, opRequestParts64)
	} else {
		b = append(b, wire.ProtocolEDonkey, opRequestParts)
	}
	b = append(b, p.Hash[:]...)
	for _, v := range append(p.Starts[:], p.Ends[:]...) {
		b = buildOffset(b, v, p.IsLarge)
	}
	return b
}

func parseRequestParts(r *wire.Reader, isLarge bool) RequestParts {
	p := RequestParts{Hash: r.Hash(), IsLarge: isLarge}
	for i := range p.Starts {
		p.Starts[i] = parseOffset(r, isLarge)
	}
	for i := range p.Ends {
		p.Ends[i] = parseOffset(r, isLarge)
	}
	return p
}

func parseOffset(r *wire.Reader, isLarge bool) uint64 {
	if isLarge {
		return r.Uint64()
	}
	return uint64(r.Uint32())
}

func buildOffset(b []byte, v uint64, isLarge bool) []byte {
	if isLarge {
		return binary.LittleEndian.AppendUint64(b, v)
	}
	return binary.LittleEndian.AppendUint32(b, uint32(v))
}

// SendingPart is OP_SENDINGPART: Data is the file bytes [Start, End).
// IsLarge sends OP_SENDINGPART_I64 with 64-bit offsets.
type SendingPart struct {
	Hash    wire.Hash
	Start   uint64
	End     uint64
	Data    []byte
	IsLarge bool
}

func (s SendingPart) Build(b []byte) []byte {
	if s.IsLarge {
		b = append(b, wire.ProtocolEMule, opSendingPart64)
	} else {
		b = append(b, wire.ProtocolEDonkey, opSendingPart)
	}
	b = append(b, s.Hash[:]...)
	b = buildOffset(buildOffset(b, s.Start, s.IsLarge), s.End, s.IsLarge)
	return append(b, s.Data...)
}

func parseSendingPart(r *wire.Reader, isLarge bool) SendingPart {
	s := SendingPart{Hash: r.Hash(), Start: parseOffset(r, isLarge), End: parseOffset(r, isLarge), IsLarge: isLarge}
	s.Data = r.Bytes(r.Len())
	if r.Err() == nil && (s.End < s.Start || s.End-s.Start != uint64(len(s.Data))) {
		r.SetErr(fmt.Errorf("client: part [%d, %d) carries %d bytes", s.Start, s.End, len(s.Data)))
	}
	return s
}

// CompressedPart is OP_COMPRESSEDPART: one zlib chunk of a block that starts
// at Start. PackedSize is the compressed size of the whole block, which
// arrives across several of these. IsLarge sends OP_COMPRESSEDPART_I64 with
// a 64-bit Start.
type CompressedPart struct {
	Hash       wire.Hash
	Start      uint64
	PackedSize uint32
	Data       []byte
	IsLarge    bool
}

func (c CompressedPart) Build(b []byte) []byte {
	op := opCompressedPart
	if c.IsLarge {
		op = opCompressedPart64
	}
	b = append(append(b, wire.ProtocolEMule, op), c.Hash[:]...)
	b = binary.LittleEndian.AppendUint32(buildOffset(b, c.Start, c.IsLarge), c.PackedSize)
	return append(b, c.Data...)
}

func parseCompressedPart(r *wire.Reader, isLarge bool) CompressedPart {
	return CompressedPart{Hash: r.Hash(), Start: parseOffset(r, isLarge), PackedSize: r.Uint32(), Data: r.Bytes(r.Len()), IsLarge: isLarge}
}

// SecureIdentState is OP_SECIDENTSTATE: which Secure User Identification
// pieces the sender still needs, and the challenge to sign.
type SecureIdentState struct {
	State     byte
	Challenge uint32
}

// SecureIdentNeedsKeyAndSignature is the only state Kelpie sends; a
// State of 1 asks for the signature alone.
const SecureIdentNeedsKeyAndSignature byte = 2

func (s SecureIdentState) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opSecureIdentState)
	return binary.LittleEndian.AppendUint32(append(b, s.State), s.Challenge)
}

// PublicKey is OP_PUBLICKEY.
type PublicKey struct{ Key []byte }

func (p PublicKey) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opPublicKey)
	return append(append(b, byte(len(p.Key))), p.Key...)
}

// Signature is OP_SIGNATURE. IPKind is present from Secure Ident v2 on and
// names which address the signature binds (identity.IPKind); 0 means
// absent.
type Signature struct {
	Signature []byte
	IPKind    byte
}

func (s Signature) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opSignature)
	b = append(append(b, byte(len(s.Signature))), s.Signature...)
	if s.IPKind != 0 {
		b = append(b, s.IPKind)
	}
	return b
}

func parseSignature(r *wire.Reader) Signature {
	s := Signature{Signature: r.Bytes(int(r.Uint8()))}
	if r.Len() > 0 {
		s.IPKind = r.Uint8()
	}
	return s
}

// PublicIPRequest is OP_PUBLICIP_REQ: a LowID peer that does not know its
// public IPv4 address asks what we see.
type PublicIPRequest struct{}

func (PublicIPRequest) Build(b []byte) []byte {
	return append(b, wire.ProtocolEMule, opPublicIPRequest)
}

// PublicIPAnswer is OP_PUBLICIP_ANSWER, the IPv4 address we see the asker at.
type PublicIPAnswer struct{ Addr netip.Addr }

func (a PublicIPAnswer) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEMule, opPublicIPAnswer)
	return binary.LittleEndian.AppendUint32(b, wire.ToClientID(a.Addr))
}

// IPv6Changed is OP_CHANGE_CLIENT_IP (ipv6-spec §3.2): the sender's public
// IPv6 changed. It travels under 0xE3, not 0xC5.
type IPv6Changed struct{ Addr netip.Addr }

func (c IPv6Changed) Build(b []byte) []byte {
	b = append(b, wire.ProtocolEDonkey, opIPv6Changed)
	return wire.BuildIPv6(b, c.Addr)
}
