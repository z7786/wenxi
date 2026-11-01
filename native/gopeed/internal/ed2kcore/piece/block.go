package piece

// Block is the byte range [Begin, End) of one block inside one part, or of
// the part of a block that is still missing.
type Block struct {
	Begin int64
	End   int64
}

func (b Block) Part() int {
	return int(b.Begin / PartSize)
}

// Index is the block's place within its part.
func (b Block) Index() int {
	return int(b.Begin % PartSize / BlockSize)
}

// PartRange is the bytes of part in a file of size bytes.
func PartRange(size int64, part int) Block {
	begin := int64(part) * PartSize
	return Block{Begin: begin, End: min(begin+PartSize, size)}
}

// BlockOf is block index of part in a file of size bytes. An index past the
// part's last block gives an empty or reversed range.
func BlockOf(size int64, part, index int) Block {
	partRange := PartRange(size, part)
	begin := partRange.Begin + int64(index)*BlockSize
	return Block{Begin: begin, End: min(begin+BlockSize, partRange.End)}
}
