// Package aich builds and checks AICH hash trees (aMule SHAHashSet.h:28-66):
// a SHA-1 of every 180 KiB block, folded pairwise up to one root. Above the
// parts the tree splits at part borders, inside a part at block borders, so
// one part's blocks can be checked against the root with only the hashes of
// the part's siblings on the way up.
package aich

import (
	"crypto/sha1"
	"hash"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

// blocksPerPart is the number of blocks in a full part, the stride of the
// leaf list between parts.
var blocksPerPart = piece.BlockCount(piece.PartSize, 0)

// Hasher computes the leaf hashes of the data written to it, which starts at
// a part border. Its zero value is ready to use.
type Hasher struct {
	block hash.Hash
	// index is the block being hashed within its part, length the bytes of
	// it hashed so far.
	index  int
	length int64
	leaves []wire.AICHHash
}

func (h *Hasher) Write(data []byte) (int, error) {
	written := len(data)
	if h.block == nil {
		h.block = sha1.New()
	}
	for len(data) > 0 {
		// Every part but the file's last is full, and the last ends with the data.
		block := piece.BlockOf(piece.PartSize, 0, h.index)
		n := min(int64(len(data)), block.End-block.Begin-h.length)
		h.block.Write(data[:n])
		h.length += n
		data = data[n:]
		if h.length == block.End-block.Begin {
			h.leaves = append(h.leaves, toAICHHash(h.block))
			h.block.Reset()
			h.length = 0
			h.index = (h.index + 1) % blocksPerPart
		}
	}
	return written, nil
}

// Leaves lists the hash of every block, the last one possibly short.
func (h *Hasher) Leaves() []wire.AICHHash {
	if h.length == 0 {
		return h.leaves
	}
	return append(h.leaves, toAICHHash(h.block))
}

func toAICHHash(h hash.Hash) wire.AICHHash {
	return wire.AICHHash(h.Sum(nil))
}

// Tree is the full hash tree of a file we have.
type Tree struct {
	size   int64
	leaves []wire.AICHHash
	root   wire.AICHHash
}

// BuildTree takes the Hasher's leaves of a whole file of size bytes.
func BuildTree(size int64, leaves []wire.AICHHash) *Tree {
	t := &Tree{size: size, leaves: leaves}
	t.root = t.buildHash(buildRoot(size))
	return t
}

func (t *Tree) Root() wire.AICHHash { return t.root }

func (t *Tree) buildHash(n node) wire.AICHHash {
	return buildNodeHash(n, func(leaf node) wire.AICHHash {
		block := piece.Block{Begin: leaf.begin}
		return t.leaves[block.Part()*blocksPerPart+block.Index()]
	})
}

// BuildRecovery is the recovery data of part, ordered as aMule writes it
// (CreatePartRecoveryData, SHAHashSet.cpp:279-326): the sibling of each node
// on the way down to the part, then the part's blocks from left to right.
func (t *Tree) BuildRecovery(part int) []client.AICHEntry {
	path, target := buildPath(t.size, part)
	var entries []client.AICHEntry
	for _, sibling := range path {
		entries = append(entries, client.AICHEntry{Ident: sibling.ident, Hash: t.buildHash(sibling)})
	}
	for _, leaf := range target.leaves() {
		entries = append(entries, client.AICHEntry{Ident: leaf.ident, Hash: t.buildHash(leaf)})
	}
	return entries
}

// MatchRecovery checks the recovery data of part against root and returns
// the part's block hashes. Like aMule's ReadRecoveryData
// (SHAHashSet.cpp:532-627) it wants exactly the siblings and the blocks,
// each once.
func MatchRecovery(root wire.AICHHash, size int64, part int, entries []client.AICHEntry) ([]wire.AICHHash, bool) {
	byIdent := map[uint32]wire.AICHHash{}
	for _, e := range entries {
		byIdent[e.Ident] = e.Hash
	}
	path, target := buildPath(size, part)
	leaves := target.leaves()
	if len(byIdent) != len(entries) || len(entries) != len(path)+len(leaves) {
		return nil, false
	}
	for _, n := range append(path, leaves...) {
		if _, ok := byIdent[n.ident]; !ok {
			return nil, false
		}
	}
	got := buildNodeHash(target, func(leaf node) wire.AICHHash { return byIdent[leaf.ident] })
	for i := len(path) - 1; i >= 0; i-- {
		sibling := path[i]
		if sibling.isLeft() {
			got = buildPairHash(byIdent[sibling.ident], got)
		} else {
			got = buildPairHash(got, byIdent[sibling.ident])
		}
	}
	if got != root {
		return nil, false
	}
	hashes := make([]wire.AICHHash, len(leaves))
	for i, leaf := range leaves {
		hashes[i] = byIdent[leaf.ident]
	}
	return hashes, true
}

// node is [begin, begin+size) of the file. ident is aMule's hash identifier:
// a leading 1 for the root, then 1 per left and 0 per right step.
type node struct {
	begin int64
	size  int64
	ident uint32
}

func buildRoot(size int64) node {
	return node{size: size, ident: 1}
}

// isLeft holds for the root too, which aMule counts as a left branch.
func (n node) isLeft() bool {
	return n.ident&1 == 1
}

func (n node) isLeaf() bool {
	return n.size <= piece.BlockSize
}

// children splits like CAICHHashTree::FindHash (SHAHashSet.cpp:126-147): in
// units of parts above one part and of blocks within, an odd unit going to
// the left child of a left branch and to the right child of a right one.
func (n node) children() (node, node) {
	unit := piece.BlockSize
	if n.size > piece.PartSize {
		unit = piece.PartSize
	}
	units := (n.size + unit - 1) / unit
	if n.isLeft() {
		units++
	}
	left := units / 2 * unit
	return node{n.begin, left, n.ident<<1 | 1}, node{n.begin + left, n.size - left, n.ident << 1}
}

func (n node) leaves() []node {
	if n.isLeaf() {
		return []node{n}
	}
	left, right := n.children()
	return append(left.leaves(), right.leaves()...)
}

// buildPath walks from the root down to part and returns the siblings
// passed on the way, top first, and the part's node.
func buildPath(size int64, part int) ([]node, node) {
	partRange := piece.PartRange(size, part)
	begin := partRange.Begin
	n := buildRoot(size)
	var siblings []node
	for n.begin != begin || n.size != partRange.End-begin {
		left, right := n.children()
		if begin < right.begin {
			siblings = append(siblings, right)
			n = left
		} else {
			siblings = append(siblings, left)
			n = right
		}
	}
	return siblings, n
}

func buildNodeHash(n node, leaf func(node) wire.AICHHash) wire.AICHHash {
	if n.isLeaf() {
		return leaf(n)
	}
	left, right := n.children()
	return buildPairHash(buildNodeHash(left, leaf), buildNodeHash(right, leaf))
}

func buildPairHash(left, right wire.AICHHash) wire.AICHHash {
	return wire.AICHHash(sha1.Sum(append(left[:], right[:]...)))
}
