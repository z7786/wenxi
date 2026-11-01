// Derived from goed2k protocol/bitfield.go.
package wire

import "encoding/binary"

// Bitfield is a part-availability map: one bit per eD2k part.
//
// Bits are packed least-significant first, as eMule reads and writes them;
// goed2k packed them most-significant first, which mislabels every part a
// real eMule peer advertises.
type Bitfield struct {
	bits []byte
	size int
}

func ToBitfield(have []bool) Bitfield {
	f := Bitfield{bits: make([]byte, (len(have)+7)/8), size: len(have)}
	for i, ok := range have {
		if ok {
			f.set(i)
		}
	}
	return f
}

func (f Bitfield) Len() int { return f.size }

func (f Bitfield) Has(i int) bool {
	if i < 0 || i >= f.size {
		return false
	}
	return f.bits[i/8]&(1<<(i%8)) != 0
}

func (f Bitfield) set(i int) { f.bits[i/8] |= 1 << (i % 8) }

// Bitfield reads a uint16 part count followed by the packed bits. A count of
// zero is how eMule says "I have the complete file".
func (r *Reader) Bitfield() Bitfield {
	size := int(r.Uint16())
	raw := r.Bytes((size + 7) / 8)
	if raw == nil && size > 0 {
		return Bitfield{}
	}
	f := Bitfield{bits: make([]byte, len(raw)), size: size}
	copy(f.bits, raw)
	if size%8 != 0 {
		f.bits[len(f.bits)-1] &= byte(1<<(size%8)) - 1
	}
	return f
}

func BuildBitfield(b []byte, f Bitfield) []byte {
	b = binary.LittleEndian.AppendUint16(b, uint16(f.size))
	return append(b, f.bits...)
}
