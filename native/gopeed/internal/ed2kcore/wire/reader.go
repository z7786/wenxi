// Derived from goed2k protocol/serializable.go and protocol/helpers.go.
package wire

import (
	"encoding/binary"
	"errors"
	"net/netip"
)

var ErrShort = errors.New("wire: body too short")

// Reader consumes a packet body. The first failure sticks: later reads
// return zero values, so a decoder checks Err once at the end.
type Reader struct {
	Rest []byte
	err  error
}

func (r *Reader) Err() error { return r.err }

func (r *Reader) Len() int { return len(r.Rest) }

func (r *Reader) SetErr(err error) {
	if r.err == nil {
		r.err = err
	}
}

func (r *Reader) Bytes(n int) []byte {
	if r.err != nil {
		return nil
	}
	if n < 0 || n > len(r.Rest) {
		r.SetErr(ErrShort)
		return nil
	}
	out := r.Rest[:n:n]
	r.Rest = r.Rest[n:]
	return out
}

func (r *Reader) Uint8() uint8 {
	b := r.Bytes(1)
	if b == nil {
		return 0
	}
	return b[0]
}

func (r *Reader) Uint16() uint16 {
	b := r.Bytes(2)
	if b == nil {
		return 0
	}
	return binary.LittleEndian.Uint16(b)
}

func (r *Reader) Uint32() uint32 {
	b := r.Bytes(4)
	if b == nil {
		return 0
	}
	return binary.LittleEndian.Uint32(b)
}

func (r *Reader) Uint64() uint64 {
	b := r.Bytes(8)
	if b == nil {
		return 0
	}
	return binary.LittleEndian.Uint64(b)
}

func (r *Reader) Hash() Hash {
	var h Hash
	copy(h[:], r.Bytes(16))
	return h
}

func (r *Reader) AICHHash() AICHHash {
	var h AICHHash
	copy(h[:], r.Bytes(20))
	return h
}

// String reads a string with a uint16 length prefix.
func (r *Reader) String() string {
	return string(r.Bytes(int(r.Uint16())))
}

// Addr reads an IPv4 address stored as its four bytes in a.b.c.d order.
// Zero means "no address".
func (r *Reader) Addr() netip.Addr {
	b := r.Bytes(4)
	if b == nil || (b[0]|b[1]|b[2]|b[3]) == 0 {
		return netip.Addr{}
	}
	return netip.AddrFrom4([4]byte(b))
}

func (r *Reader) AddrPort() netip.AddrPort {
	addr := r.Addr()
	port := r.Uint16()
	if !addr.IsValid() {
		if port == 0 {
			return netip.AddrPort{}
		}
		addr = netip.IPv4Unspecified()
	}
	return netip.AddrPortFrom(addr, port)
}

// IPv6 reads 16 raw address bytes in network order.
func (r *Reader) IPv6() netip.Addr {
	b := r.Bytes(16)
	if b == nil {
		return netip.Addr{}
	}
	return netip.AddrFrom16([16]byte(b))
}

func BuildString(b []byte, s string) []byte {
	b = binary.LittleEndian.AppendUint16(b, uint16(len(s)))
	return append(b, s...)
}

// BuildAddr writes an IPv4 address as a.b.c.d; anything else becomes zero.
func BuildAddr(b []byte, addr netip.Addr) []byte {
	if !addr.Is4() {
		return append(b, 0, 0, 0, 0)
	}
	a := addr.As4()
	return append(b, a[:]...)
}

func BuildAddrPort(b []byte, ap netip.AddrPort) []byte {
	b = BuildAddr(b, ap.Addr())
	return binary.LittleEndian.AppendUint16(b, ap.Port())
}

func BuildIPv6(b []byte, addr netip.Addr) []byte {
	a := addr.As16()
	return append(b, a[:]...)
}
