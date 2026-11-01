package peer

import (
	"bytes"
	"compress/zlib"
	"path"
	"slices"
	"strings"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/aich"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

const (
	// eMule splits each block it uploads into packets of this size.
	partPacketSize = 10240
	// eMule's AddReqBlock refuses a requested range longer than three
	// EMBLOCKSIZE blocks.
	maxRequestSize = 3 * piece.BlockSize
	// maxUploadBlocks bounds the blocks a peer may have requested and not
	// yet received, and the sent blocks remembered: aMule keeps at most 32
	// requests open to one uploader (DownloadClient.cpp:603).
	maxUploadBlocks = 32
)

// Share is one of our files as offered to peers. Parts is what we can
// upload; PartHashes is empty for files below one part. Tree is the AICH
// tree of a complete file, nil until built.
type Share struct {
	Name       string
	Size       int64
	Parts      piece.Set
	PartHashes []wire.Hash
	Tree       *aich.Tree
}

type uploadBlock struct {
	file  wire.Hash
	block piece.Block
}

// pendingBlock is what sending a requested block needs of its file.
type pendingBlock struct {
	isLarge   bool
	isArchive bool
}

// archiveExtensions are aMule's ED2KFT_ARCHIVE file types
// (OtherFunctions.cpp:929-), whose blocks it never tries to compress
// (UploadDiskIOThread.cpp:252): they do not shrink.
var archiveExtensions = map[string]bool{
	".7z": true, ".ace": true, ".alz": true, ".arc": true, ".arj": true, ".bz2": true,
	".cab": true, ".cb7": true, ".cba": true, ".cbr": true, ".cbt": true, ".cbz": true,
	".gz": true, ".hqx": true, ".lha": true, ".lz": true, ".lz4": true, ".lzh": true,
	".lzma": true, ".pak": true, ".par": true, ".par2": true, ".rar": true, ".sea": true,
	".sit": true, ".sitx": true, ".tar": true, ".tbz2": true, ".tgz": true, ".tlz": true,
	".txz": true, ".uc2": true, ".xz": true, ".z": true, ".zip": true, ".zoo": true,
	".zst": true,
}

func isArchive(name string) bool {
	return archiveExtensions[strings.ToLower(path.Ext(name))]
}

// uploadState is the upload role. Like eMule we hold one slot per client;
// while it is open the peer may request blocks of any file we share.
type uploadState struct {
	// file is what the peer last asked about, for an OP_STARTUPLOADREQ that
	// carries no hash.
	file wire.Hash
	// parts holds, per file, what the peer's file request said it has.
	parts map[wire.Hash]piece.Set
	// slot is nil while the peer holds no upload slot.
	slot *uploadSlot
}

// uploadSlot remembers the blocks requested and not yet sent, and the last
// ones sent, oldest first, so a peer re-listing blocks still in flight gets
// each only once.
type uploadSlot struct {
	pending map[uploadBlock]pendingBlock
	sent    []uploadBlock
}

// StartUpload gives the peer an upload slot. A peer that already holds one
// gets OP_ACCEPTUPLOADREQ again and keeps the blocks it has requested, as
// aMule answers a downloading client (UploadQueue.cpp:520-528): it would not
// ask for them again.
func (s *Session) StartUpload() Output {
	var out Output
	if s.up.slot == nil {
		s.up.slot = &uploadSlot{pending: map[uploadBlock]pendingBlock{}}
	}
	out.send(client.AcceptUploadRequest{})
	return out
}

// StopUpload ends the peer's upload slot.
func (s *Session) StopUpload() Output {
	var out Output
	if s.up.slot != nil {
		s.up.slot = nil
		out.send(client.OutOfParts{})
	}
	return out
}

// SendQueueRank tells a waiting peer its place in our upload queue.
func (s *Session) SendQueueRank(rank uint32) Output {
	var out Output
	if s.features.isEmule {
		out.send(client.QueueRanking{Rank: uint16(min(rank, 0xFFFF))})
	} else {
		out.send(client.QueueRank{Rank: rank})
	}
	return out
}

// SendBlock uploads one block the peer requested, compressed when the peer
// supports it, the file is not an archive, and compression makes it smaller.
func (s *Session) SendBlock(file wire.Hash, block piece.Block, data []byte) Output {
	var out Output
	slot := s.up.slot
	if slot == nil {
		return out
	}
	key := uploadBlock{file, block}
	pending, ok := slot.pending[key]
	if !ok {
		return out
	}
	delete(slot.pending, key)
	if slot.sent = append(slot.sent, key); len(slot.sent) > maxUploadBlocks {
		slot.sent = slot.sent[1:]
	}
	if s.features.canCompress && !pending.isArchive {
		if packed := toDeflated(data); len(packed) < len(data) {
			for chunk := range slices.Chunk(packed, partPacketSize) {
				out.send(client.CompressedPart{Hash: file, Start: uint64(block.Begin), PackedSize: uint32(len(packed)), Data: chunk, IsLarge: pending.isLarge})
			}
			return out
		}
	}
	start := block.Begin
	for chunk := range slices.Chunk(data, partPacketSize) {
		end := start + int64(len(chunk))
		out.send(client.SendingPart{Hash: file, Start: uint64(start), End: uint64(end), Data: chunk, IsLarge: pending.isLarge})
		start = end
	}
	return out
}

// toDeflated packs at zlib's fastest level, as eMule 0.70b and aMule do
// (UploadDiskIOThread.cpp:521-529): 1.5 to 2.5 times faster than the default
// for 4 to 12 percent more bytes.
func toDeflated(data []byte) []byte {
	var packed bytes.Buffer
	w, _ := zlib.NewWriterLevel(&packed, zlib.BestSpeed)
	w.Write(data)
	w.Close()
	return packed.Bytes()
}

func (s *Session) onFileRequest(p client.FileRequest, out *Output) {
	share, ok := s.cfg.ShareByHash(p.Hash)
	if !ok {
		out.send(client.NoFile{Hash: p.Hash})
		return
	}
	s.up.file = p.Hash
	s.setRequestedParts(p, share)
	out.send(client.FileNameAnswer{Hash: p.Hash, Name: share.Name})
}

func (s *Session) setRequestedParts(p client.FileRequest, share Share) {
	if !p.HasParts {
		return
	}
	if parts, ok := toPartSet(p.Parts, share.Size); ok {
		s.up.parts[p.Hash] = parts
	}
}

func (s *Session) onStatusRequest(file wire.Hash, out *Output) {
	share, ok := s.cfg.ShareByHash(file)
	if !ok {
		out.send(client.NoFile{Hash: file})
		return
	}
	s.up.file = file
	out.send(client.FileStatus{Hash: file, Parts: ToStatus(share)})
}

// ToStatus is our part status of share for OP_FILESTATUS and the UDP reask:
// no parts for a complete file, as eMule sends.
func ToStatus(share Share) wire.Bitfield {
	if share.Parts.IsFull() {
		return wire.Bitfield{}
	}
	return toBitfield(share.Parts, share.Size)
}

// onMultiPacket answers the bundled requests in one OP_MULTIPACKETANSWER,
// or OP_MULTIPACKETANSWER_EXT2 led by our identifier when isExt2
// (ListenSocket.cpp:1072-1297). OP_MULTIPACKET carries no size.
func (s *Session) onMultiPacket(id client.FileIdentifier, requests []wire.Packet, isExt2 bool, now time.Time, out *Output) {
	file := id.Hash
	share, ok := s.cfg.ShareByHash(file)
	if !ok || !matchFile(id, share) {
		out.send(client.NoFile{Hash: file})
		return
	}
	s.up.file = file
	var answers []wire.Packet
	var sourcesRequest *client.RequestSources2
	for _, request := range requests {
		switch r := request.(type) {
		case client.FileRequest:
			s.setRequestedParts(r, share)
			answers = append(answers, client.FileNameAnswer{Hash: file, Name: share.Name})
		case client.SetRequestFileID:
			answers = append(answers, client.FileStatus{Hash: file, Parts: ToStatus(share)})
		case client.RequestSources2:
			sourcesRequest = &r
		case client.AICHFileHashRequest:
			// eMule ignores it once the root travels in the identifier
			// (ListenSocket.cpp:1206).
			if isExt2 || s.features.hasFileIdentifiers {
				continue
			}
			if root, ok := s.onRootRequest(file, share, out); ok {
				answers = append(answers, root)
			}
		}
	}
	switch {
	case isExt2:
		if share.Tree == nil {
			s.requestTree(file, share, out)
		}
		if len(answers) > 0 {
			out.send(client.MultiPacketAnswerExt2{File: toIdentifier(file, share), Answers: answers})
		}
	case len(answers) > 0:
		out.send(client.MultiPacketAnswer{Hash: file, Answers: answers})
	}
	if sourcesRequest != nil {
		s.onSourcesRequest(*sourcesRequest, now, out)
	}
}

func (s *Session) onHashSetRequest(file wire.Hash, out *Output) {
	if share, ok := s.cfg.ShareByHash(file); ok && len(share.PartHashes) > 0 {
		out.send(client.HashSetAnswer{Hash: file, Parts: share.PartHashes})
	}
}

// onHashSetRequest2 answers with the MD4 part hashes only; eMule closes on
// a file it does not share (UploadClient.cpp:572-605).
func (s *Session) onHashSetRequest2(p client.HashSetRequest2, out *Output) {
	share, ok := s.cfg.ShareByHash(p.File.Hash)
	if !ok || !matchFile(p.File, share) {
		out.Close = closeProtocol
		return
	}
	if !p.IsMD4Wanted && !p.IsAICHWanted {
		return
	}
	answer := client.HashSetAnswer2{File: toIdentifier(p.File.Hash, share)}
	if p.IsMD4Wanted {
		answer.Parts = share.PartHashes
	}
	out.send(answer)
}

// matchFile is eMule's CompareRelaxed (FileIdentifier.cpp:75-82): size and
// root count only when both sides know them.
func matchFile(id client.FileIdentifier, share Share) bool {
	if id.Size != 0 && id.Size != uint64(share.Size) {
		return false
	}
	return !id.HasRoot || share.Tree == nil || share.Tree.Root() == id.Root
}

func toIdentifier(file wire.Hash, share Share) client.FileIdentifier {
	id := client.FileIdentifier{Hash: file, Size: uint64(share.Size)}
	if share.Tree != nil {
		id.HasRoot, id.Root = true, share.Tree.Root()
	}
	return id
}

func (s *Session) onUploadRequest(file wire.Hash, out *Output) {
	if file == (wire.Hash{}) {
		file = s.up.file
	}
	if _, ok := s.cfg.ShareByHash(file); !ok {
		return
	}
	s.up.file = file
	out.add(UploadRequested{File: file, Parts: s.up.parts[file]})
}

func (s *Session) onPartsRequest(file wire.Hash, blocks []piece.Block, out *Output) {
	share, ok := s.cfg.ShareByHash(file)
	slot := s.up.slot
	if slot == nil || !ok {
		return
	}
	var fresh []piece.Block
	for _, b := range blocks {
		key := uploadBlock{file, b}
		_, isPending := slot.pending[key]
		isFull := len(slot.pending) >= maxUploadBlocks
		if isPending || isFull || slices.Contains(slot.sent, key) || !canUpload(share, b) {
			continue
		}
		slot.pending[key] = pendingBlock{isLarge: share.Size > largeFileSize, isArchive: isArchive(share.Name)}
		fresh = append(fresh, b)
	}
	if len(fresh) > 0 {
		out.add(BlocksRequested{File: file, Blocks: fresh})
	}
}

// canUpload tells whether we can send b of share: a range eMule's
// AddReqBlock accepts, within parts we have.
func canUpload(share Share, b piece.Block) bool {
	if b.End > share.Size || b.End-b.Begin > maxRequestSize {
		return false
	}
	return share.Parts[b.Part()] && share.Parts[piece.Block{Begin: b.End - 1}.Part()]
}

func (s *Session) onUploadCancelled(out *Output) {
	s.up.slot = nil
	out.add(UploadCancelled{})
}

func toBlocks(p client.RequestParts) []piece.Block {
	var blocks []piece.Block
	for i := range p.Starts {
		if p.Ends[i] > p.Starts[i] {
			blocks = append(blocks, piece.Block{Begin: int64(p.Starts[i]), End: int64(p.Ends[i])})
		}
	}
	return blocks
}
