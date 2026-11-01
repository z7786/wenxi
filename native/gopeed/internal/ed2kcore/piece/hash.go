package piece

import (
	"slices"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const (
	PartSize int64 = 9_728_000
	// BlockSize is eMule's EMBLOCKSIZE. A part holds 52 full blocks and a
	// shorter last one; blocks never cross a part boundary.
	BlockSize int64 = 184_320
)

// PartCount is the number of parts that hold data. A file whose size is an
// exact multiple of PartSize has no trailing empty part here.
func PartCount(size int64) int {
	return int((size + PartSize - 1) / PartSize)
}

func BlockCount(size int64, part int) int {
	return int((partLength(size, part) + BlockSize - 1) / BlockSize)
}

func partLength(size int64, part int) int64 {
	partRange := PartRange(size, part)
	return partRange.End - partRange.Begin
}

// HashCount is the length of a file's hash set. Files below PartSize have none:
// their file hash is the hash of the data. From PartSize up, eMule hashes the
// remainder after the last full part even when it is empty, so a file of
// exactly n parts has n+1 part hashes.
func HashCount(size int64) int {
	if size < PartSize {
		return 0
	}
	return int(size/PartSize) + 1
}

// BuildFileHash derives the file hash from a non-empty hash set.
func BuildFileHash(partHashes []wire.Hash) wire.Hash {
	var hasher MD4
	for _, hash := range partHashes {
		hasher.Write(hash[:])
	}
	return hasher.Digest()
}

// FileHasher computes the ed2k file hash and hash set of the data written to it.
// Its zero value is ready to use.
type FileHasher struct {
	part       MD4
	partLength int64
	fullParts  []wire.Hash
}

func (h *FileHasher) Write(data []byte) (int, error) {
	written := len(data)
	for len(data) > 0 {
		n := min(int64(len(data)), PartSize-h.partLength)
		h.part.Write(data[:n])
		h.partLength += n
		data = data[n:]
		if h.partLength == PartSize {
			h.fullParts = append(h.fullParts, h.part.Digest())
			h.part = MD4{}
			h.partLength = 0
		}
	}
	return written, nil
}

func (h *FileHasher) FileHash() wire.Hash {
	if len(h.fullParts) == 0 {
		return h.part.Digest()
	}
	return BuildFileHash(h.PartHashes())
}

// PartHashes is the hash set, empty for files below PartSize (see HashCount).
func (h *FileHasher) PartHashes() []wire.Hash {
	if len(h.fullParts) == 0 {
		return nil
	}
	return append(slices.Clone(h.fullParts), h.part.Digest())
}
