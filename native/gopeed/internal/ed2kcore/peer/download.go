package peer

import (
	"bytes"
	"compress/zlib"
	"io"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

// OLD_MAX_EMULE_FILE_SIZE: larger files need the 64-bit part packets.
const largeFileSize = 4_290_048_000

// aMule 3.1 keeps in flight twice the blocks a peer sends in a round trip,
// plus three, at most 24 (amule-org 3.1.0 DownloadClient.cpp:557-597). A
// fixed depth caps a peer at that many blocks a round trip: eMule's six give
// 4.2 MiB/s at 250 ms, and a fast peer far away idles between bursts.
const (
	minPipeline = 3
	maxPipeline = 24
)

// downloadState is the download role. Every added file is probed for the
// peer's parts, but the upload slot, which eD2k grants per client and not per
// file, is asked for one file at a time: the first one added, once
// Config.CanAskSlot lets it start. started is that file, zero until then.
type downloadState struct {
	files    []*download
	started  wire.Hash
	slot     slot
	lastData time.Time
	// slotStart is when the slot was granted, slotBytes what arrived in it
	// since, and roundTrip how long its first data took: the first blocks
	// are requested at the grant.
	slotStart time.Time
	slotBytes int64
	roundTrip time.Duration
}

// pipeline is how many blocks to keep in flight; the rate counts the slot up
// to its last data.
func (d *downloadState) pipeline() int {
	seconds := d.lastData.Sub(d.slotStart).Seconds()
	if seconds <= 0 {
		return minPipeline
	}
	blocks := float64(d.slotBytes) / seconds * d.roundTrip.Seconds() / float64(piece.BlockSize)
	return min(2*int(blocks)+minPipeline, maxPipeline)
}

// slot is where our upload slot with the peer stands. A peer may grant one
// we never asked for, typically on a connection it opened to us.
type slot byte

const (
	slotIdle slot = iota
	slotAsked
	slotGranted
)

type download struct {
	file      wire.Hash
	size      int64
	parts     piece.Set
	hashSet   hashSet
	peerParts piece.Set
	inFlight  []*inFlight
}

// hashSet is where our request for a file's part hashes stands; the
// request waits for the peer's part status.
type hashSet byte

const (
	hashSetNone hashSet = iota
	hashSetWanted
	hashSetRequested
	hashSetAnswered
)

type inFlight struct {
	block piece.Block
	data  []byte
	// prefix counts the bytes received from the block's start without a gap;
	// ranges holds what arrived beyond a gap.
	prefix int64
	ranges []piece.Block
	packed []byte
	// handed counts the bytes from the block's start already handed over.
	handed int64
	// payload counts the packet data that arrived for the block since the
	// last hand-over, which credits count rather than the block's size
	// (BlockReceived.Payload).
	payload int64
}

// Add asks the peer about file, of which we have parts. It may be called
// from the moment the session is built; before the handshake completes the
// request waits for it.
func (s *Session) Add(file wire.Hash, size int64, parts piece.Set) Output {
	var out Output
	if s.downloadByHash(file) != nil {
		return out
	}
	d := &download{file: file, size: size, parts: parts}
	s.down.files = append(s.down.files, d)
	if s.greeting == handshaken {
		s.sendFileRequest(d, &out)
	}
	s.startFirstFile(&out)
	return out
}

// Remove forgets file, cancelling its slot if it holds one, and lets the
// next file start. The engine releases the blocks it had requested.
func (s *Session) Remove(file wire.Hash) Output {
	var out Output
	if s.down.started == file && s.down.slot == slotGranted {
		out.send(client.CancelTransfer{})
	}
	s.removeFile(file, &out)
	s.startFirstFile(&out)
	return out
}

// Files lists the files the connection serves, in the order added.
func (s *Session) Files() []wire.Hash {
	files := make([]wire.Hash, 0, len(s.down.files))
	for _, d := range s.down.files {
		files = append(files, d.file)
	}
	return files
}

func (s *Session) downloadByHash(file wire.Hash) *download {
	for _, d := range s.down.files {
		if d.file == file {
			return d
		}
	}
	return nil
}

// startFirstFile starts the oldest file once the handshake names the peer
// and the engine's A4AF rules let us ask this client for it.
func (s *Session) startFirstFile(out *Output) {
	if s.greeting != handshaken || s.down.started != (wire.Hash{}) || len(s.down.files) == 0 {
		return
	}
	first := s.down.files[0].file
	if !s.cfg.CanAskSlot(s.caps.UserHash, first) {
		return
	}
	s.down.started = first
	s.runStarted(out)
}

// RequestHashSet asks the peer for file's part hashes once it has told its
// part status. aMule asks one source per file, right after its OP_FILESTATUS,
// and asks every other source for a slot meanwhile (DownloadClient.cpp:467-482);
// the transfer picks that source.
func (s *Session) RequestHashSet(file wire.Hash) Output {
	var out Output
	if d := s.downloadByHash(file); d != nil && d.hashSet == hashSetNone {
		d.hashSet = hashSetWanted
		s.sendHashSetRequest(d, &out)
	}
	return out
}

func (s *Session) sendHashSetRequest(d *download, out *Output) {
	if d.hashSet == hashSetWanted && d.peerParts != nil {
		d.hashSet = hashSetRequested
		out.send(client.HashSetRequest{Hash: d.file})
	}
}

// Request sends block requests for file, three ranges per packet as the
// protocol allows. The engine passes at most the Count of the last
// BlocksWanted.
func (s *Session) Request(file wire.Hash, blocks []piece.Block) Output {
	var out Output
	d := s.downloadByHash(file)
	if d == nil || s.down.slot != slotGranted || s.down.started != file {
		return out
	}
	// aMule gives back a slot that yields nothing to request
	// (DownloadClient.cpp:646-689).
	if len(blocks) == 0 && len(d.inFlight) == 0 {
		out.send(client.CancelTransfer{})
		s.stopSlot(&out)
		out.add(NoNeededParts{File: file})
		return out
	}
	for _, b := range blocks {
		d.inFlight = append(d.inFlight, &inFlight{block: b})
	}
	for group := range slices.Chunk(blocks, 3) {
		p := client.RequestParts{Hash: file, IsLarge: d.size > largeFileSize}
		for i, b := range group {
			p.Starts[i], p.Ends[i] = uint64(b.Begin), uint64(b.End)
		}
		out.send(p)
	}
	return out
}

// Stop gives up every block in flight on a closing connection.
func (s *Session) Stop() Output {
	var out Output
	s.cancelInFlight(s.down.started, &out)
	return out
}

func (s *Session) removeFile(file wire.Hash, out *Output) {
	s.cancelInFlight(file, out)
	s.down.files = slices.DeleteFunc(s.down.files, func(d *download) bool { return d.file == file })
	delete(s.sx.asked, file)
	if s.down.started == file {
		s.down = downloadState{files: s.down.files}
	}
}

// canServe tells whether the peer can serve d: one without large file
// support cannot serve a file above 4 GB.
func (s *Session) canServe(d *download) bool {
	return d.size <= largeFileSize || s.features.hasLargeFiles
}

// rejectLargeFiles drops, at the handshake, the files the peer cannot serve.
func (s *Session) rejectLargeFiles(out *Output) {
	for _, d := range slices.Clone(s.down.files) {
		if !s.canServe(d) {
			s.removeFile(d.file, out)
			out.add(FileRejected{File: d.file})
		}
	}
}

func (s *Session) sendFileRequest(d *download, out *Output) {
	if !s.canServe(d) {
		s.removeFile(d.file, out)
		out.add(FileRejected{File: d.file})
		return
	}
	file := d.file
	request := client.FileRequest{Hash: file}
	// eMule reads these extensions by the version the sender advertised,
	// which for us is client.ExtendedRequestsVersion.
	if s.features.extendedRequests > 0 {
		request.HasParts, request.Parts = true, toBitfield(d.parts, d.size)
		request.HasCompleteSources = true
	}
	requests := []wire.Packet{request}
	// A single-part file needs no status: the peer that names it has it all.
	if piece.PartCount(d.size) > 1 {
		requests = append(requests, client.SetRequestFileID{Hash: file})
	}
	// With file identifiers the root comes in the answer's identifier
	// (DownloadClient.cpp:385-391).
	if s.features.hasAICH && !s.features.hasFileIdentifiers {
		requests = append(requests, client.AICHFileHashRequest{Hash: file})
	}
	s.sendMultiPacket(file, d.size, requests, out)
}

// sendMultiPacket bundles requests for file in the newest multipacket the
// peer supports, as eMule picks it (DownloadClient.cpp:316-400).
func (s *Session) sendMultiPacket(file wire.Hash, size int64, requests []wire.Packet, out *Output) {
	switch {
	case s.features.hasFileIdentifiers:
		out.send(client.MultiPacketExt2{File: client.FileIdentifier{Hash: file, Size: uint64(size)}, Requests: requests})
	case s.features.hasExtMultiPacket:
		out.send(client.MultiPacketExt{Hash: file, Size: uint64(size), Requests: requests})
	case s.features.hasMultiPacket:
		out.send(client.MultiPacket{Hash: file, Requests: requests})
	default:
		out.send(requests...)
	}
}

// onMultiPacketAnswerExt2 closes on an identifier whose size is not the
// file's and takes its AICH root as the peer's report, as eMule does
// (ListenSocket.cpp:1312-1324).
func (s *Session) onMultiPacketAnswerExt2(p client.MultiPacketAnswerExt2, out *Output) {
	d := s.downloadByHash(p.File.Hash)
	if d == nil {
		return
	}
	if p.File.Size != 0 && p.File.Size != uint64(d.size) {
		out.Close = closeProtocol
		return
	}
	if p.File.HasRoot {
		s.onRoot(p.File.Hash, p.File.Root, out)
	}
	s.onMultiPacketAnswer(p.Answers, out)
}

func (s *Session) onMultiPacketAnswer(answers []wire.Packet, out *Output) {
	for _, answer := range answers {
		switch a := answer.(type) {
		case client.FileNameAnswer:
			s.onFileName(a.Hash, out)
		case client.FileStatus:
			s.onFileStatus(a, out)
		case client.AICHFileHashAnswer:
			s.onRoot(a.Hash, a.Root, out)
		}
	}
}

func (s *Session) onFileName(file wire.Hash, out *Output) {
	d := s.downloadByHash(file)
	if d == nil || d.peerParts != nil || piece.PartCount(d.size) > 1 {
		return
	}
	s.setPeerParts(d, piece.BuildFullSet(1), out)
}

func (s *Session) onFileStatus(p client.FileStatus, out *Output) {
	d := s.downloadByHash(p.Hash)
	if d == nil {
		return
	}
	parts, ok := toPartSet(p.Parts, d.size)
	if !ok {
		out.Close = closeProtocol
		return
	}
	s.setPeerParts(d, parts, out)
}

func (s *Session) setPeerParts(d *download, parts piece.Set, out *Output) {
	d.peerParts = parts
	out.add(StatusReceived{File: d.file, Parts: parts})
	s.sendHashSetRequest(d, out)
	s.runStarted(out)
}

func (s *Session) onHashSet(p client.HashSetAnswer, out *Output) {
	d := s.downloadByHash(p.Hash)
	if d == nil || d.hashSet != hashSetRequested {
		return
	}
	d.hashSet = hashSetAnswered
	// aMule drops a client that sends a wrong hash set (DownloadClient.cpp:584-585).
	if len(p.Parts) != piece.HashCount(d.size) || piece.BuildFileHash(p.Parts) != p.Hash {
		out.Close = closeProtocol
		return
	}
	out.add(HashSetReceived{File: p.Hash, Hashes: p.Parts})
}

func (s *Session) onNoFile(file wire.Hash, out *Output) {
	if s.downloadByHash(file) == nil {
		return
	}
	s.removeFile(file, out)
	out.add(FileRejected{File: file})
	s.startFirstFile(out)
}

// runStarted moves the started file on as far as what we know allows: ask for
// a slot, or once granted, ask the engine for blocks. A peer with no part we
// still need is not asked for a slot (aMule DS_NONEEDEDPARTS,
// DownloadClient.cpp:459-466).
func (s *Session) runStarted(out *Output) {
	d := s.downloadByHash(s.down.started)
	if d == nil || d.peerParts == nil {
		return
	}
	switch {
	case s.down.slot == slotGranted:
		s.requestBlocks(d, out)
	case s.down.slot == slotIdle && hasNeededPart(d):
		s.down.slot = slotAsked
		out.send(client.StartUploadRequest{Hash: s.down.started})
		out.add(SlotAsked{File: s.down.started})
	case s.down.slot == slotIdle:
		out.add(NoNeededParts{File: s.down.started})
	}
}

func hasNeededPart(d *download) bool {
	for i, has := range d.peerParts {
		if has && (i >= len(d.parts) || !d.parts[i]) {
			return true
		}
	}
	return false
}

func (s *Session) requestBlocks(d *download, out *Output) {
	if room := s.down.pipeline() - len(d.inFlight); room > 0 {
		out.add(BlocksWanted{File: s.down.started, Count: room})
	}
}

func (s *Session) onQueueRank(rank uint32, out *Output) {
	s.stopSlot(out)
	if s.down.started != (wire.Hash{}) {
		out.add(Queued{File: s.down.started, Rank: rank})
	}
}

func (s *Session) onSlotGranted(now time.Time, out *Output) {
	if s.down.slot == slotGranted {
		return
	}
	s.down.slot = slotGranted
	s.down.lastData = now
	s.down.slotStart, s.down.slotBytes = now, 0
	out.add(SlotGranted{File: s.down.started})
	s.runStarted(out)
}

func (s *Session) onData(n int, now time.Time) {
	if s.down.slotBytes == 0 {
		s.down.roundTrip = now.Sub(s.down.slotStart)
	}
	s.down.lastData = now
	s.down.slotBytes += int64(n)
}

func (s *Session) stopSlot(out *Output) {
	if s.down.slot != slotGranted {
		return
	}
	s.down.slot = slotIdle
	s.cancelInFlight(s.down.started, out)
	out.add(Queued{File: s.down.started})
}

func (s *Session) hasBlocksInFlight() bool {
	d := s.downloadByHash(s.down.started)
	return d != nil && len(d.inFlight) > 0
}

func (s *Session) onPart(file wire.Hash, start int64, data []byte, now time.Time, out *Output) {
	d := s.downloadByHash(file)
	if d == nil {
		return
	}
	end := start + int64(len(data))
	i := slices.IndexFunc(d.inFlight, func(f *inFlight) bool { return f.block.Begin <= start && end <= f.block.End })
	if i < 0 {
		return
	}
	s.onData(len(data), now)
	f := d.inFlight[i]
	f.payload += int64(len(data))
	if f.data == nil {
		f.data = make([]byte, f.block.End-f.block.Begin)
	}
	copy(f.data[start-f.block.Begin:], data)
	f.ranges = append(f.ranges, piece.Block{Begin: start, End: end})
	f.updatePrefix()
	if f.prefix == int64(len(f.data)) {
		s.onBlockFilled(file, d, i, f.data, out)
		return
	}
	handOver(file, f, f.data[:f.prefix], out)
}

func (f *inFlight) updatePrefix() {
	for isGrown := true; isGrown; {
		isGrown = false
		end := f.block.Begin + f.prefix
		for _, r := range f.ranges {
			if r.Begin <= end && end < r.End {
				end, isGrown = r.End, true
			}
		}
		f.prefix = end - f.block.Begin
	}
	f.ranges = slices.DeleteFunc(f.ranges, func(r piece.Block) bool { return r.End <= f.block.Begin+f.prefix })
}

// cancelInFlight gives up file's block requests and hands over what arrived
// of each block from its start and is not handed over yet: aMule later asks
// only for the gaps (DownloadClient.cpp:835-848), and inflates a compressed
// block as its packets arrive.
func (s *Session) cancelInFlight(file wire.Hash, out *Output) {
	d := s.downloadByHash(file)
	if d == nil {
		return
	}
	for _, f := range d.inFlight {
		handOver(file, f, toReceived(f), out)
	}
	d.inFlight = nil
}

// handOver hands over the part of received, f's data from the block's start,
// that is new since the last hand-over, and the payload not yet counted, even
// of a packet beyond a gap. aMule writes and credits every packet as it comes
// (DownloadClient.cpp:835-865), so Progress and the rate move with each packet
// rather than once a 180 KB block is complete. The data is copied: a late
// duplicate packet may still be copied into the block while the disk writes
// what was handed over.
func handOver(file wire.Hash, f *inFlight, received []byte, out *Output) {
	if int64(len(received)) == f.handed && f.payload == 0 {
		return
	}
	data := slices.Clone(received[f.handed:])
	begin := f.block.Begin + f.handed
	out.add(BlockReceived{File: file, Block: piece.Block{Begin: begin, End: begin + int64(len(data))}, Data: data, Payload: f.payload})
	f.handed, f.payload = int64(len(received)), 0
}

// toReceived is the block's data received without a gap from its start; for
// a compressed block, what its zlib stream so far inflates to.
func toReceived(f *inFlight) []byte {
	if f.packed == nil {
		return f.data[:f.prefix]
	}
	size := f.block.End - f.block.Begin
	plain, _ := toInflated(f.packed, size)
	return plain[:min(int64(len(plain)), size)]
}

// onCompressedPart collects one block's zlib stream, which the uploader
// splits across packets that all carry the block's start and packed size.
func (s *Session) onCompressedPart(file wire.Hash, start int64, packedSize uint32, data []byte, now time.Time, out *Output) {
	d := s.downloadByHash(file)
	if d == nil {
		return
	}
	i := slices.IndexFunc(d.inFlight, func(f *inFlight) bool { return f.block.Begin == start })
	if i < 0 {
		return
	}
	s.onData(len(data), now)
	f := d.inFlight[i]
	f.payload += int64(len(data))
	size := f.block.End - f.block.Begin
	// eMule packs into a buffer 300 bytes larger than the block and sends
	// the block plain unless packing shrinks it (UploadDiskIOThread.cpp:581-583).
	if int64(packedSize) > size+300 || len(f.packed)+len(data) > int(packedSize) {
		s.cancelBlock(file, d, i, out)
		return
	}
	f.packed = append(f.packed, data...)
	if len(f.packed) < int(packedSize) {
		return
	}
	plain, err := toInflated(f.packed, size)
	if err != nil || int64(len(plain)) != size {
		s.cancelBlock(file, d, i, out)
		return
	}
	s.onBlockFilled(file, d, i, plain, out)
}

// cancelBlock gives up a compressed block whose stream is broken and
// ignores the rest of it, keeping the connection: aMule does not
// disconnect, as the next block's stream may be good
// (DownloadClient.cpp:988-1015). The transfer hands the block out again
// once this slot ends.
func (s *Session) cancelBlock(file wire.Hash, d *download, i int, out *Output) {
	d.inFlight = slices.Delete(d.inFlight, i, i+1)
	if s.down.slot == slotGranted && s.down.started == file {
		s.requestBlocks(d, out)
	}
}

func (s *Session) onBlockFilled(file wire.Hash, d *download, i int, data []byte, out *Output) {
	handOver(file, d.inFlight[i], data, out)
	d.inFlight = slices.Delete(d.inFlight, i, i+1)
	if s.down.slot == slotGranted && s.down.started == file {
		s.requestBlocks(d, out)
	}
}

func toInflated(packed []byte, size int64) ([]byte, error) {
	r, err := zlib.NewReader(bytes.NewReader(packed))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(io.LimitReader(r, size+1))
}

// toPartSet reads OP_FILESTATUS, whose count is eMule's ED2K part count,
// size/PARTSIZE+1, one more than PartCount for a file of whole parts. Zero
// parts means the peer has the complete file.
func toPartSet(f wire.Bitfield, size int64) (piece.Set, bool) {
	count := piece.PartCount(size)
	if f.Len() == 0 {
		return piece.BuildFullSet(count), true
	}
	if f.Len() != int(size/piece.PartSize)+1 {
		return nil, false
	}
	parts := make(piece.Set, count)
	for i := range parts {
		parts[i] = f.Has(i)
	}
	return parts, true
}

func toBitfield(parts piece.Set, size int64) wire.Bitfield {
	have := make([]bool, size/piece.PartSize+1)
	copy(have, parts)
	return wire.ToBitfield(have)
}
