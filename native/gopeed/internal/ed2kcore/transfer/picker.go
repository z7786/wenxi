package transfer

import (
	"fmt"
	"math/rand/v2"
	"slices"
	"sort"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
)

func blockAt(size, offset int64) piece.Block {
	return piece.BlockOf(size, int(offset/piece.PartSize), int(offset%piece.PartSize/piece.BlockSize))
}

// blockState tracks a block byte by byte, as aMule keeps byte-granular gaps
// (DownloadClient.cpp:835-848), so a block cut off when a slot ends is
// finished by asking only for its missing tail. Data arrives in order, so
// what is received is always a prefix.
type blockState struct {
	received int64
	written  int64
	// requester is the peer asked for the rest of the block, 0 while none
	// is: a block is never asked of two peers at once, as aMule 3.1.0 hands
	// a block over only after cancelling its slow source
	// (DownloadClient.cpp:624-697).
	requester uint64
	senders   []uint64
}

type partState struct {
	isVerified bool
	// blocks is nil until the part is first touched and again after it is
	// verified or reset.
	blocks []blockState
}

// picker decides which blocks of the file to request from which peer, named
// by its connection id.
type picker struct {
	size         int64
	random       *rand.Rand
	parts        []partState
	availability []int
	peerParts    map[uint64]piece.Set
}

// buildPicker restores the parts verified and the blocks written before a
// restart, as aMule's .part.met keeps its gap list. A written block is a
// whole block or, for a block cut off when a slot ended, its leading piece
// [Begin, Begin+n).
func buildPicker(size int64, verified piece.Set, written []piece.Block, random *rand.Rand) (*picker, error) {
	p := &picker{
		size:         size,
		random:       random,
		parts:        make([]partState, piece.PartCount(size)),
		availability: make([]int, piece.PartCount(size)),
		peerParts:    map[uint64]piece.Set{},
	}
	for part, isVerified := range verified {
		if !isVerified {
			continue
		}
		if part >= len(p.parts) {
			return nil, fmt.Errorf("resume data: part %d out of range", part)
		}
		p.parts[part].isVerified = true
	}
	for _, block := range written {
		whole := blockAt(size, block.Begin)
		if block.Begin < 0 || block.Begin >= size || whole.Begin != block.Begin || block.End <= block.Begin || block.End > whole.End {
			return nil, fmt.Errorf("resume data: [%d, %d) is not the start of a block of this file", block.Begin, block.End)
		}
		if !p.parts[block.Part()].isVerified {
			state := p.blockState(block)
			state.received = block.End - block.Begin
			state.written = state.received
		}
	}
	return p, nil
}

// writtenBlocks lists what buildPicker takes back after a restart: the
// written bytes of parts not yet verified.
func (p *picker) writtenBlocks() []piece.Block {
	var written []piece.Block
	for i, part := range p.parts {
		// Disk workers may finish writes out of order, so a block's
		// received prefix is on disk only once every write of it is done.
		for j, state := range part.blocks {
			if state.written > 0 && state.written == state.received {
				block := piece.BlockOf(p.size, i, j)
				written = append(written, piece.Block{Begin: block.Begin, End: block.Begin + state.written})
			}
		}
	}
	return written
}

func (p *picker) blockState(b piece.Block) *blockState {
	part := &p.parts[b.Part()]
	if part.blocks == nil {
		part.blocks = make([]blockState, piece.BlockCount(p.size, b.Part()))
	}
	return &part.blocks[b.Index()]
}

func (p *picker) verifiedParts() piece.Set {
	set := make(piece.Set, len(p.parts))
	for i, part := range p.parts {
		set[i] = part.isVerified
	}
	return set
}

// writtenParts lists parts whose blocks are all on disk but whose hash has not
// been checked yet, as happens after a restart.
func (p *picker) writtenParts() []int {
	var parts []int
	for i := range p.parts {
		if p.isWritten(i) {
			parts = append(parts, i)
		}
	}
	return parts
}

func (p *picker) isWritten(part int) bool {
	state := p.parts[part]
	if state.isVerified || state.blocks == nil {
		return false
	}
	for j, block := range state.blocks {
		if b := piece.BlockOf(p.size, part, j); block.written != b.End-b.Begin {
			return false
		}
	}
	return true
}

func (p *picker) writtenSize() int64 {
	var written int64
	for i, part := range p.parts {
		if part.isVerified {
			partRange := piece.PartRange(p.size, i)
			written += partRange.End - partRange.Begin
			continue
		}
		for _, block := range part.blocks {
			written += block.written
		}
	}
	return written
}

// onPeerParts replaces what the picker knows a peer has.
func (p *picker) onPeerParts(peer uint64, parts piece.Set) {
	p.removeAvailability(peer)
	p.peerParts[peer] = slices.Clone(parts)
	for i, has := range parts {
		if has {
			p.availability[i]++
		}
	}
}

func (p *picker) onPeerGone(peer uint64) {
	p.cancel(peer)
	p.removeAvailability(peer)
	delete(p.peerParts, peer)
}

func (p *picker) removeAvailability(peer uint64) {
	for i, has := range p.peerParts[peer] {
		if has {
			p.availability[i]--
		}
	}
}

// cancel releases every block the peer was asked for and has not delivered,
// so other peers can take them.
func (p *picker) cancel(peer uint64) {
	for i := range p.parts {
		for j := range p.parts[i].blocks {
			if block := &p.parts[i].blocks[j]; block.requester == peer {
				block.requester = 0
			}
		}
	}
}

// request picks up to n blocks no peer is asked for, to ask this peer for,
// and records them as requested, in the order of candidateParts; a partly
// received block is asked for from where it stops.
func (p *picker) request(peer uint64, n int) []piece.Block {
	var picked []piece.Block
	for _, part := range p.candidateParts(peer) {
		for index := range piece.BlockCount(p.size, part) {
			if len(picked) == n {
				return picked
			}
			b := piece.BlockOf(p.size, part, index)
			state := p.blockState(b)
			if state.received < b.End-b.Begin && state.requester == 0 {
				state.requester = peer
				picked = append(picked, piece.Block{Begin: b.Begin + state.received, End: b.End})
			}
		}
	}
	return picked
}

// hasNeededPart tells whether the peer has a part not yet verified.
func (p *picker) hasNeededPart(peer uint64) bool {
	for i, has := range p.peerParts[peer] {
		if has && !p.parts[i].isVerified {
			return true
		}
	}
	return false
}

func (p *picker) isRequesting(peer uint64) bool {
	for _, part := range p.parts {
		for _, block := range part.blocks {
			if block.requester == peer {
				return true
			}
		}
	}
	return false
}

// hasBlocksFor tells whether a block owner is asked for lies in a part
// other has (aMule HasUsefulBlocksFor, DownloadClient.cpp:1739-1754).
func (p *picker) hasBlocksFor(owner, other uint64) bool {
	for i, has := range p.peerParts[other] {
		if !has {
			continue
		}
		for _, block := range p.parts[i].blocks {
			if block.requester == owner {
				return true
			}
		}
	}
	return false
}

// candidateParts orders the parts the peer has and we need, simplifying
// aMule's chunk rank (PartFile.cpp:2131-2316): the parts the peer is already
// asked for, then very rare parts, then parts no peer is asked for, then the
// rest; within each, rarer first, then the more received, then at random.
// Spreading peers over parts nobody downloads spreads the rare parts before
// their sources leave, and keeps the senders of each part few.
func (p *picker) candidateParts(peer uint64) []int {
	// aMule's very rare bound: a tenth of the sources, at least one.
	veryRare := max(1, len(p.peerParts)/10)
	type candidate struct {
		part     int
		rank     int
		received int64
	}
	var candidates []candidate
	for i, has := range p.peerParts[peer] {
		if !has || p.parts[i].isVerified {
			continue
		}
		c := candidate{part: i, rank: 3}
		isAsked, isAskedOfOthers := false, false
		for _, block := range p.parts[i].blocks {
			c.received += block.received
			isAsked = isAsked || block.requester == peer
			isAskedOfOthers = isAskedOfOthers || block.requester != 0 && block.requester != peer
		}
		switch {
		case isAsked:
			c.rank = 0
		case p.availability[i] <= veryRare:
			c.rank = 1
		case !isAskedOfOthers:
			c.rank = 2
		}
		candidates = append(candidates, c)
	}
	p.random.Shuffle(len(candidates), func(i, j int) { candidates[i], candidates[j] = candidates[j], candidates[i] })
	sort.SliceStable(candidates, func(i, j int) bool {
		a, b := candidates[i], candidates[j]
		if a.rank != b.rank {
			return a.rank < b.rank
		}
		if p.availability[a.part] != p.availability[b.part] {
			return p.availability[a.part] < p.availability[b.part]
		}
		return a.received > b.received
	})
	parts := make([]int, len(candidates))
	for i, c := range candidates {
		parts[i] = c.part
	}
	return parts
}

// onBlockReceived records that the data of b, a block or a leading piece of
// what was requested of it, arrived from peer. It returns the bytes of b that
// are new and should be written; false when another peer delivered them first,
// as a slow source cancelled in the endgame may have, or the part is already
// verified. The block stays requested until it is complete or the peer's
// requests are cancelled.
func (p *picker) onBlockReceived(peer uint64, b piece.Block) (piece.Block, bool) {
	if p.parts[b.Part()].isVerified {
		return piece.Block{}, false
	}
	whole := blockAt(p.size, b.Begin)
	state := p.blockState(b)
	next := whole.Begin + state.received
	if b.Begin > next || b.End <= next {
		return piece.Block{}, false
	}
	state.received = b.End - whole.Begin
	if !slices.Contains(state.senders, peer) {
		state.senders = append(state.senders, peer)
	}
	if b.End == whole.End {
		state.requester = 0
	}
	return piece.Block{Begin: next, End: b.End}, true
}

// onBlockWritten records that b, as returned by onBlockReceived, is on disk
// and reports whether its whole part is now written and ready to be hashed.
func (p *picker) onBlockWritten(b piece.Block) bool {
	p.blockState(b).written += b.End - b.Begin
	return p.isWritten(b.Part())
}

// onPartVerified marks a part verified and returns how many of its bytes
// each peer sent, a block counting whole for every peer that sent any of it.
func (p *picker) onPartVerified(part int) map[uint64]int64 {
	sent := map[uint64]int64{}
	for i, block := range p.parts[part].blocks {
		b := piece.BlockOf(p.size, part, i)
		for _, sender := range block.senders {
			sent[sender] += b.End - b.Begin
		}
	}
	p.parts[part] = partState{isVerified: true}
	return sent
}

// onPartFailed discards a part whose hash did not match.
func (p *picker) onPartFailed(part int) {
	p.parts[part] = partState{}
}

// senders lists the peers that sent any block of a part not yet verified.
func (p *picker) senders() []uint64 {
	var senders []uint64
	for _, part := range p.parts {
		for _, block := range part.blocks {
			for _, sender := range block.senders {
				if !slices.Contains(senders, sender) {
					senders = append(senders, sender)
				}
			}
		}
	}
	return senders
}

// onBlockFailed discards one whole block of a part that failed its hash
// check, so only that block is requested again, and returns its senders.
func (p *picker) onBlockFailed(b piece.Block) []uint64 {
	state := p.blockState(b)
	senders := state.senders
	*state = blockState{}
	return senders
}

// onBlockVerified returns the senders of a block that AICH found good and
// forgets them, so the block counts for them once, not again when its part
// is verified.
func (p *picker) onBlockVerified(b piece.Block) []uint64 {
	state := p.blockState(b)
	senders := state.senders
	state.senders = nil
	return senders
}
