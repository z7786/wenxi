// Derived from goed2k protocol/md4.go.

package piece

import (
	"encoding/binary"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const md4ChunkSize = 64

// MD4 is an incremental RFC 1320 hasher. Its zero value is ready to use, and
// Digest leaves it unchanged so more data can follow.
type MD4 struct {
	state   [4]uint32
	chunk   [md4ChunkSize]byte
	used    int
	length  uint64
	isReady bool
}

func (h *MD4) Write(data []byte) (int, error) {
	if !h.isReady {
		h.state = [4]uint32{0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476}
		h.isReady = true
	}
	written := len(data)
	h.length += uint64(written)
	if h.used > 0 {
		n := copy(h.chunk[h.used:], data)
		h.used += n
		data = data[n:]
		if h.used < md4ChunkSize {
			return written, nil
		}
		runMD4Chunk(&h.state, h.chunk[:])
		h.used = 0
	}
	for len(data) >= md4ChunkSize {
		runMD4Chunk(&h.state, data[:md4ChunkSize])
		data = data[md4ChunkSize:]
	}
	h.used = copy(h.chunk[:], data)
	return written, nil
}

func (h *MD4) Digest() wire.Hash {
	final := *h
	bitLength := final.length * 8
	padding := [md4ChunkSize + 8]byte{0x80}
	padLength := (md4ChunkSize + 56 - final.used) % md4ChunkSize
	if padLength == 0 {
		padLength = md4ChunkSize
	}
	final.Write(padding[:padLength])
	var lengthBytes [8]byte
	binary.LittleEndian.PutUint64(lengthBytes[:], bitLength)
	final.Write(lengthBytes[:])

	var digest wire.Hash
	for i, word := range final.state {
		binary.LittleEndian.PutUint32(digest[4*i:], word)
	}
	return digest
}

func runMD4Chunk(state *[4]uint32, chunk []byte) {
	var x [16]uint32
	for j := range x {
		x[j] = binary.LittleEndian.Uint32(chunk[4*j:])
	}
	a, b, c, d := state[0], state[1], state[2], state[3]

	a = ff(a, b, c, d, x[0], 3)
	d = ff(d, a, b, c, x[1], 7)
	c = ff(c, d, a, b, x[2], 11)
	b = ff(b, c, d, a, x[3], 19)
	a = ff(a, b, c, d, x[4], 3)
	d = ff(d, a, b, c, x[5], 7)
	c = ff(c, d, a, b, x[6], 11)
	b = ff(b, c, d, a, x[7], 19)
	a = ff(a, b, c, d, x[8], 3)
	d = ff(d, a, b, c, x[9], 7)
	c = ff(c, d, a, b, x[10], 11)
	b = ff(b, c, d, a, x[11], 19)
	a = ff(a, b, c, d, x[12], 3)
	d = ff(d, a, b, c, x[13], 7)
	c = ff(c, d, a, b, x[14], 11)
	b = ff(b, c, d, a, x[15], 19)

	a = gg(a, b, c, d, x[0], 3)
	d = gg(d, a, b, c, x[4], 5)
	c = gg(c, d, a, b, x[8], 9)
	b = gg(b, c, d, a, x[12], 13)
	a = gg(a, b, c, d, x[1], 3)
	d = gg(d, a, b, c, x[5], 5)
	c = gg(c, d, a, b, x[9], 9)
	b = gg(b, c, d, a, x[13], 13)
	a = gg(a, b, c, d, x[2], 3)
	d = gg(d, a, b, c, x[6], 5)
	c = gg(c, d, a, b, x[10], 9)
	b = gg(b, c, d, a, x[14], 13)
	a = gg(a, b, c, d, x[3], 3)
	d = gg(d, a, b, c, x[7], 5)
	c = gg(c, d, a, b, x[11], 9)
	b = gg(b, c, d, a, x[15], 13)

	a = hh(a, b, c, d, x[0], 3)
	d = hh(d, a, b, c, x[8], 9)
	c = hh(c, d, a, b, x[4], 11)
	b = hh(b, c, d, a, x[12], 15)
	a = hh(a, b, c, d, x[2], 3)
	d = hh(d, a, b, c, x[10], 9)
	c = hh(c, d, a, b, x[6], 11)
	b = hh(b, c, d, a, x[14], 15)
	a = hh(a, b, c, d, x[1], 3)
	d = hh(d, a, b, c, x[9], 9)
	c = hh(c, d, a, b, x[5], 11)
	b = hh(b, c, d, a, x[13], 15)
	a = hh(a, b, c, d, x[3], 3)
	d = hh(d, a, b, c, x[11], 9)
	c = hh(c, d, a, b, x[7], 11)
	b = hh(b, c, d, a, x[15], 15)

	state[0] += a
	state[1] += b
	state[2] += c
	state[3] += d
}

func ff(a, b, c, d, x uint32, s uint) uint32 {
	return rol(a+((b&c)|(^b&d))+x, s)
}

func gg(a, b, c, d, x uint32, s uint) uint32 {
	return rol(a+((b&c)|(b&d)|(c&d))+x+0x5a827999, s)
}

func hh(a, b, c, d, x uint32, s uint) uint32 {
	return rol(a+(b^c^d)+x+0x6ed9eba1, s)
}

func rol(x uint32, s uint) uint32 {
	return (x << s) | (x >> (32 - s))
}
