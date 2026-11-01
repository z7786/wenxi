package transfer

import (
	"maps"
	"math/rand/v2"
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/aich"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

// A root reported by sources is trusted once this many address prefixes
// sent it and they are this share of all prefixes that sent a root
// (MINUNIQUEIPS_TOTRUST and MINPERCENTAGE_TOTRUST, SHAHashSet.cpp:43-44).
const (
	minTrustPrefixes = 10
	minTrustPercent  = 92
)

// maxCorruptPercent is CBB_BANTHRESHOLD (CorruptionBlackBox.cpp:39): a
// source is banned once more than this share of what it sent and a hash
// checked was corrupt.
const maxCorruptPercent = 32

// RequestRecovery asks a peer for the AICH recovery data of a part that
// failed its MD4 check; the engine answers with OnRecovery or
// OnRecoveryFailed.
type RequestRecovery struct {
	Peer uint64
	Part int
	Root wire.AICHHash
}

// HashBlocks reads [Begin, End) back from disk and hashes each block with
// SHA-1; the engine answers with OnBlocksHashed or OnDiskFailed.
type HashBlocks struct{ Part int }

func (RequestRecovery) isAction() {}
func (HashBlocks) isAction()      {}

// aichState is the file's AICH root and the repairs of parts that failed
// their MD4 check.
type aichState struct {
	// linkedRoot came with the link, aMule's AICH_VERIFIED; votes do not
	// change it.
	linkedRoot wire.AICHHash
	// isBroken: a repair found every block good in a part MD4 rejected, so
	// the root cannot be right (aMule AICH_ERROR, PartFile.cpp:3970-3979).
	isBroken bool
	votes    []rootVote
	// roots holds the root each connected peer reported.
	roots map[uint64]wire.AICHHash
	// asked maps a part under repair to the peer asked for its recovery data.
	asked map[int]uint64
	// verified holds a part's checked block hashes until ours are hashed.
	verified map[int][]wire.AICHHash
	random   *rand.Rand
}

type rootVote struct {
	root     wire.AICHHash
	prefixes map[netip.Prefix]bool
}

func buildAICHState(root wire.AICHHash, random *rand.Rand) aichState {
	return aichState{
		linkedRoot: root,
		roots:      map[uint64]wire.AICHHash{},
		asked:      map[int]uint64{},
		verified:   map[int][]wire.AICHHash{},
		random:     random,
	}
}

func (s *aichState) isLinked() bool {
	return s.linkedRoot != (wire.AICHHash{})
}

// root is the linked root, or else the one the most prefixes voted for,
// first come on a tie, and tells whether it is trusted.
func (s *aichState) root() (wire.AICHHash, bool) {
	if s.isLinked() {
		return s.linkedRoot, !s.isBroken
	}
	if len(s.votes) == 0 {
		return wire.AICHHash{}, false
	}
	total, best := 0, 0
	for i, v := range s.votes {
		total += len(v.prefixes)
		if len(v.prefixes) > len(s.votes[best].prefixes) {
			best = i
		}
	}
	count := len(s.votes[best].prefixes)
	return s.votes[best].root, !s.isBroken && count >= minTrustPrefixes && 100*count/total >= minTrustPercent
}

// OnRoot records the AICH root a connected peer reported for the file and
// counts it as that peer's vote (aMule UntrustedHashReceived,
// SHAHashSet.cpp:930-1010).
func (t *Transfer) OnRoot(peer uint64, root wire.AICHHash) {
	s := t.peers[peer]
	if !t.isDownloading() || s == nil {
		return
	}
	t.aich.roots[peer] = root
	if t.aich.isLinked() || t.aich.isBroken {
		return
	}
	prefix := toVotePrefix(s.Endpoint.Addr())
	i := slices.IndexFunc(t.aich.votes, func(v rootVote) bool { return v.root == root })
	if i < 0 {
		t.aich.votes = append(t.aich.votes, rootVote{root: root, prefixes: map[netip.Prefix]bool{}})
		i = len(t.aich.votes) - 1
	}
	t.aich.votes[i].prefixes[prefix] = true
}

// toVotePrefix counts IPv4 voters per /20, as aMule's AddSigningIP masks
// them (SHAHashSet.cpp:743). aMule has no IPv6; a /48 is one site.
func toVotePrefix(addr netip.Addr) netip.Prefix {
	addr = addr.Unmap()
	bits := 20
	if addr.Is6() {
		bits = 48
	}
	prefix, _ := addr.Prefix(bits)
	return prefix
}

// requestRecovery asks a source for the recovery data of a part that failed its
// MD4 check (aMule RequestAICHRecovery, PartFile.cpp:3813-3891): one that
// reported the trusted root, has no request pending and is not held (see
// holdUntil), HighID first, at random. Without one the part is
// thrown away whole and nobody is banned: MD4 cannot tell which sender was
// corrupt, and banning all of them would let one bad source ban the good
// ones (aMule PartFile.cpp:3719-3732).
func (t *Transfer) requestRecovery(part int, now time.Time) []Action {
	root, isTrusted := t.aich.root()
	if !isTrusted || piece.BlockCount(t.file.Size, part) == 1 {
		t.picker.onPartFailed(part)
		return nil
	}
	var highIDs, lowIDs []uint64
	for _, peer := range slices.Sorted(maps.Keys(t.aich.roots)) {
		s := t.peers[peer]
		if s == nil || t.aich.roots[peer] != root || t.isAsked(peer) || now.Before(s.holdUntil()) {
			continue
		}
		if s.ClientID == 0 {
			highIDs = append(highIDs, peer)
		} else {
			lowIDs = append(lowIDs, peer)
		}
	}
	candidates := highIDs
	if len(candidates) == 0 {
		candidates = lowIDs
	}
	if len(candidates) == 0 {
		t.picker.onPartFailed(part)
		return nil
	}
	peer := candidates[t.aich.random.IntN(len(candidates))]
	t.aich.asked[part] = peer
	t.peers[peer].addRequest(now, false)
	return []Action{RequestRecovery{Peer: peer, Part: part, Root: root}}
}

func (t *Transfer) isAsked(peer uint64) bool {
	for _, asked := range t.aich.asked {
		if asked == peer {
			return true
		}
	}
	return false
}

// OnRecovery takes the recovery data a peer sent for part. Data that does
// not lead to the trusted root counts as a failed answer.
func (t *Transfer) OnRecovery(peer uint64, part int, root wire.AICHHash, entries []client.AICHEntry, now time.Time) []Action {
	if asked, ok := t.aich.asked[part]; !ok || asked != peer || !t.isDownloading() {
		return nil
	}
	trusted, isTrusted := t.aich.root()
	hashes, ok := aich.MatchRecovery(trusted, t.file.Size, part, entries)
	if !ok || root != trusted || !isTrusted {
		return t.OnRecoveryFailed(peer, now)
	}
	delete(t.aich.asked, part)
	t.aich.verified[part] = hashes
	return []Action{HashBlocks{Part: part}}
}

// OnRecoveryFailed: the peer could not give the recovery data it was asked
// for, or is gone. Its root is forgotten and another source is asked
// (ClientAICHRequestFailed, SHAHashSet.cpp:1014-1028).
func (t *Transfer) OnRecoveryFailed(peer uint64, now time.Time) []Action {
	delete(t.aich.roots, peer)
	for part, asked := range t.aich.asked {
		if asked == peer {
			delete(t.aich.asked, part)
			if t.isDownloading() {
				return t.requestRecovery(part, now)
			}
		}
	}
	return nil
}

// OnBlocksHashed compares our blocks of a part under repair with the
// checked ones: the good blocks stay, the bad ones are downloaded again, and
// a sender of a bad block is banned once its share of corrupt data is above
// maxCorruptPercent (AICHRecoveryDataAvailable, PartFile.cpp:3895-4010;
// CCorruptionBlackBox::EvaluateData). A bad block counts whole for every
// peer that sent any of it, and as a full BlockSize even when it is the
// short last block of a part, as aMule counts corrupt data as at least
// EMBLOCKSIZE (CorruptionBlackBox.cpp:166-169).
func (t *Transfer) OnBlocksHashed(part int, hashes []wire.AICHHash, now time.Time) []Action {
	verified, ok := t.aich.verified[part]
	delete(t.aich.verified, part)
	if !ok || !t.isDownloading() {
		return nil
	}
	isGood := func(i int) bool { return i < len(hashes) && hashes[i] == verified[i] }
	isCorrupt := false
	for i := range verified {
		isCorrupt = isCorrupt || !isGood(i)
	}
	if !isCorrupt {
		t.aich.isBroken = true
		t.picker.onPartFailed(part)
		return nil
	}
	var suspects []uint64
	for i := range verified {
		b := piece.BlockOf(t.file.Size, part, i)
		if isGood(i) {
			for _, peer := range t.picker.onBlockVerified(b) {
				if s := t.senders[peer]; s != nil {
					s.goodBytes += b.End - b.Begin
				}
			}
			continue
		}
		for _, peer := range t.picker.onBlockFailed(b) {
			if s := t.senders[peer]; s != nil {
				s.badBytes += piece.BlockSize
			}
			if !slices.Contains(suspects, peer) {
				suspects = append(suspects, peer)
			}
		}
	}
	var actions []Action
	for _, peer := range suspects {
		if s := t.senders[peer]; s != nil && s.badBytes*100 > maxCorruptPercent*(s.badBytes+s.goodBytes) {
			actions = append(actions, t.removeCorrupt(peer, now)...)
		}
	}
	return actions
}
