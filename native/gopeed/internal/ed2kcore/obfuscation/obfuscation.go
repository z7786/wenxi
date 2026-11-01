// Package obfuscation is eMule's protocol obfuscation for TCP connections:
// an RC4 stream keyed by the receiving client's user hash between clients,
// or by a Diffie-Hellman agreement with a server. Clients that require it
// close a plain connection as soon as our Hello arrives; on the real network
// those were the fastest sources of a hot file.
package obfuscation

import (
	"bufio"
	"crypto/rc4"
	"encoding/binary"
	"errors"
	"io"
	"math/big"
	"math/rand/v2"
	"net"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const (
	// MAGICVALUE_REQUESTER and MAGICVALUE_SERVER salt the key of each
	// direction; MAGICVALUE_SYNC opens the encrypted handshake.
	magicRequester byte   = 34
	magicServer    byte   = 203
	magicSync      uint32 = 0x835E6FC4
	// methodObfuscation is ENM_OBFUSCATION, the only method eMule defines.
	methodObfuscation byte = 0x00
	// rc4Discard is how much keystream eMule throws away after keying.
	rc4Discard = 1024
	// primeSize is PRIMESIZE_BYTES, the length of every number in the
	// server handshake.
	primeSize = 96
	// Each handshake step ends in random padding, so that its length is no
	// fingerprint: up to CryptTCPPaddingLength (254 by default) between
	// clients, but under 16 towards a server, which takes no more
	// (EncryptedStreamSocket.cpp:464, 493, 619-627, 724).
	maxPadding       = 254
	maxServerPadding = 15
)

// dhPrime is dh768_p, the fixed prime of the server handshake
// (aMule EncryptedStreamSocket.cpp:104-117); the generator is 2.
var dhPrime = new(big.Int).SetBytes([]byte{
	0xF2, 0xBF, 0x52, 0xC5, 0x5F, 0x58, 0x7A, 0xDD, 0x53, 0x71, 0xA9, 0x36,
	0xE8, 0x86, 0xEB, 0x3C, 0x62, 0x17, 0xA3, 0x3E, 0xC3, 0x4C, 0xB4, 0x0D,
	0xC7, 0x3A, 0x41, 0xA6, 0x43, 0xAF, 0xFC, 0xE7, 0x21, 0xFC, 0x28, 0x63,
	0x66, 0x53, 0x5B, 0xDB, 0xCE, 0x25, 0x9F, 0x22, 0x86, 0xDA, 0x4A, 0x91,
	0xB2, 0x07, 0xCB, 0xAA, 0x52, 0x55, 0xD4, 0xF6, 0x1C, 0xCE, 0xAE, 0xD4,
	0x5A, 0xD5, 0xE0, 0x74, 0x7D, 0xF7, 0x78, 0x18, 0x28, 0x10, 0x5F, 0x34,
	0x0F, 0x76, 0x23, 0x87, 0xF8, 0x8B, 0x28, 0x91, 0x42, 0xFB, 0x42, 0x68,
	0x8F, 0x05, 0x15, 0x0F, 0x54, 0x8B, 0x5F, 0x43, 0x6A, 0xF7, 0x0D, 0xF3,
})

var errHandshake = errors.New("obfuscation: bad handshake")

// cipherConn encrypts what it writes and decrypts what it reads. Read and
// Write may run on different goroutines.
type cipherConn struct {
	net.Conn
	r    io.Reader
	in   *rc4.Cipher
	out  *rc4.Cipher
	wbuf []byte
}

func (c *cipherConn) Read(b []byte) (int, error) {
	n, err := c.r.Read(b)
	c.in.XORKeyStream(b[:n], b[:n])
	return n, err
}

func (c *cipherConn) Write(b []byte) (int, error) {
	c.wbuf = append(c.wbuf[:0], b...)
	c.out.XORKeyStream(c.wbuf, c.wbuf)
	return c.Conn.Write(c.wbuf)
}

// buildPadding is <PaddingLen 1><Padding> with up to max random bytes.
func buildPadding(random *rand.Rand, max int) []byte {
	padding := make([]byte, 1+random.IntN(max+1))
	padding[0] = byte(len(padding) - 1)
	for i := 1; i < len(padding); i++ {
		padding[i] = byte(random.Uint32())
	}
	return padding
}

// readAnswer reads <MagicValue 4><MethodSelected 1><PaddingLen 1><Padding>.
func (c *cipherConn) readAnswer() error {
	var head [6]byte
	if _, err := io.ReadFull(c.r, head[:]); err != nil {
		return err
	}
	c.in.XORKeyStream(head[:], head[:])
	if binary.LittleEndian.Uint32(head[:]) != magicSync || head[4] != methodObfuscation {
		return errHandshake
	}
	return c.discard(int(head[5]))
}

func (c *cipherConn) discard(n int) error {
	padding := make([]byte, n)
	if _, err := io.ReadFull(c.r, padding); err != nil {
		return err
	}
	c.in.XORKeyStream(padding, padding)
	return nil
}

// buildCipher is a datagram cipher that has thrown away the start of its
// keystream, as eMule's streams do.
func buildCipher(parts ...[]byte) *rc4.Cipher {
	c := buildDatagramCipher(parts...)
	discard := make([]byte, rc4Discard)
	c.XORKeyStream(discard, discard)
	return c
}

// matchPlain tells whether the first byte of a connection starts a plain
// eD2k frame.
func matchPlain(b byte) bool {
	return b == wire.ProtocolEDonkey || b == wire.ProtocolEMule || b == wire.ProtocolPacked
}

// OpenOutgoing starts obfuscation on a connection we opened to the client
// with user hash user. keyPart is random; it salts both keys, and random
// pads the request. It blocks until the peer has answered, as eMule holds
// its Hello until then (aMule drops a peer that sends more than the
// handshake step needs): the caller closes conn to give up.
//
// Request: <Marker 1><KeyPart 4>, then encrypted <MagicValue 4>
// <MethodsSupported 1><MethodPreferred 1><PaddingLen 1><Padding>.
func OpenOutgoing(conn net.Conn, user wire.Hash, keyPart [4]byte, random *rand.Rand) (net.Conn, error) {
	c := &cipherConn{
		Conn: conn,
		r:    bufio.NewReader(conn),
		in:   buildCipher(user[:], []byte{magicServer}, keyPart[:]),
		out:  buildCipher(user[:], []byte{magicRequester}, keyPart[:]),
	}
	marker := keyPart[0] ^ keyPart[3]
	for matchPlain(marker) {
		marker++
	}
	request := binary.LittleEndian.AppendUint32(nil, magicSync)
	request = append(request, methodObfuscation, methodObfuscation)
	request = append(request, buildPadding(random, maxPadding)...)
	c.out.XORKeyStream(request, request)
	if _, err := conn.Write(append(append([]byte{marker}, keyPart[:]...), request...)); err != nil {
		return nil, err
	}
	if err := c.readAnswer(); err != nil {
		return nil, err
	}
	return c, nil
}

// OpenServer starts obfuscation on a connection we opened to a server's
// obfuscation port. A server has no user hash to key with, so the key is
// agreed by Diffie-Hellman; secret is our 128-bit exponent and marker a
// random first byte (aMule EncryptedStreamSocket.cpp:56-81, 398-424,
// 603-668); random pads the request and the reply. It blocks until the
// server has answered: the caller closes conn to give up.
//
// Request, plain: <Marker 1><g^a mod p 96><PaddingLen 1><Padding>. Answer:
// plain <g^b mod p 96>, then encrypted <MagicValue 4><MethodsSupported 1>
// <MethodPreferred 1><PaddingLen 1><Padding>. Reply, encrypted:
// <MagicValue 4><MethodSelected 1><PaddingLen 1><Padding>.
func OpenServer(conn net.Conn, secret [16]byte, marker byte, random *rand.Rand) (net.Conn, error) {
	a := new(big.Int).SetBytes(secret[:])
	for matchPlain(marker) {
		marker++
	}
	request := make([]byte, 1+primeSize)
	request[0] = marker
	new(big.Int).Exp(big.NewInt(2), a, dhPrime).FillBytes(request[1:])
	if _, err := conn.Write(append(request, buildPadding(random, maxServerPadding)...)); err != nil {
		return nil, err
	}
	r := bufio.NewReader(conn)
	shared := make([]byte, primeSize)
	if _, err := io.ReadFull(r, shared); err != nil {
		return nil, err
	}
	new(big.Int).Exp(new(big.Int).SetBytes(shared), a, dhPrime).FillBytes(shared)
	c := &cipherConn{
		Conn: conn,
		r:    r,
		in:   buildCipher(shared, []byte{magicServer}),
		out:  buildCipher(shared, []byte{magicRequester}),
	}
	var head [7]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return nil, err
	}
	c.in.XORKeyStream(head[:], head[:])
	if binary.LittleEndian.Uint32(head[:]) != magicSync {
		return nil, errHandshake
	}
	if err := c.discard(int(head[6])); err != nil {
		return nil, err
	}
	reply := binary.LittleEndian.AppendUint32(nil, magicSync)
	reply = append(reply, methodObfuscation)
	if _, err := c.Write(append(reply, buildPadding(random, maxServerPadding)...)); err != nil {
		return nil, err
	}
	return c, nil
}

// OpenIncoming reads the first byte of a connection a peer opened to us,
// whose user hash is self. A plain eD2k frame is returned as it came; an
// obfuscation request is answered, padded by random, and the encrypted
// connection returned. It blocks until the peer has sent its handshake: the
// caller closes conn to give up.
//
// The answer is padded as towards a server: a server we log in to tests
// our port with this handshake and takes no more (aMule
// EncryptedStreamSocket.cpp:619-627), and who connected is not known yet.
//
// eMule and aMule drop a peer whose first read holds more than the
// handshake. Kelpie keeps such bytes for the reader instead: a requester
// that waits for our answer, as eMule and Kelpie do, never sends them, and
// whether early bytes share one read is up to TCP.
func OpenIncoming(conn net.Conn, self wire.Hash, random *rand.Rand) (net.Conn, error) {
	r := bufio.NewReader(conn)
	first, err := r.Peek(1)
	if err != nil {
		return nil, err
	}
	if matchPlain(first[0]) {
		return &plainConn{Conn: conn, r: r}, nil
	}
	var head [1 + 4 + 7]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return nil, err
	}
	keyPart := [4]byte(head[1:5])
	c := &cipherConn{
		Conn: conn,
		r:    r,
		in:   buildCipher(self[:], []byte{magicRequester}, keyPart[:]),
		out:  buildCipher(self[:], []byte{magicServer}, keyPart[:]),
	}
	request := head[5:]
	c.in.XORKeyStream(request, request)
	// request[4] lists the methods the peer supports, request[5] its
	// preferred one; obfuscation is the only method and always supported.
	if binary.LittleEndian.Uint32(request) != magicSync {
		return nil, errHandshake
	}
	if err := c.discard(int(request[6])); err != nil {
		return nil, err
	}
	answer := binary.LittleEndian.AppendUint32(nil, magicSync)
	answer = append(answer, methodObfuscation)
	if _, err := c.Write(append(answer, buildPadding(random, maxServerPadding)...)); err != nil {
		return nil, err
	}
	return c, nil
}

// plainConn gives back the byte OpenIncoming peeked at.
type plainConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *plainConn) Read(b []byte) (int, error) { return c.r.Read(b) }
