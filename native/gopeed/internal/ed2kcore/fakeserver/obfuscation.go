package fakeserver

import (
	"bufio"
	"crypto/md5"
	"crypto/rand"
	"crypto/rc4"
	"encoding/binary"
	"errors"
	"io"
	"math/big"
	"net"
)

// The server side of aMule's obfuscated server login
// (EncryptedStreamSocket.cpp:56-81): Diffie-Hellman over dh768_p with g = 2,
// then RC4 keyed with MD5(S|magic). Kelpie only ever plays the client, so
// this side lives here.
const (
	magicRequester byte   = 34
	magicServer    byte   = 203
	magicSync      uint32 = 0x835E6FC4
	primeSize             = 96
)

var dhPrime, _ = new(big.Int).SetString("F2BF52C55F587ADD5371A936E886EB3C6217A33EC34CB40DC73A41A643AFFCE7"+
	"21FC286366535BDBCE259F2286DA4A91B207CBAA5255D4F61CCEAED45AD5E0747DF7781828105F340F762387F88B2891"+
	"42FB42688F05150F548B5F436AF70DF3", 16)

var errHandshake = errors.New("fakeserver: bad obfuscation handshake")

type cryptConn struct {
	net.Conn
	r   io.Reader
	in  *rc4.Cipher
	out *rc4.Cipher
}

func (c *cryptConn) Read(b []byte) (int, error) {
	n, err := c.r.Read(b)
	c.in.XORKeyStream(b[:n], b[:n])
	return n, err
}

// Write is called under the client's write lock.
func (c *cryptConn) Write(b []byte) (int, error) {
	buf := make([]byte, len(b))
	c.out.XORKeyStream(buf, b)
	return c.Conn.Write(buf)
}

// openObfuscated answers a client's obfuscation request: <marker 1>
// <g^a 96><padding length 1><padding>, then reads its encrypted
// <magic 4><method 1><padding length 1><padding>.
func openObfuscated(conn net.Conn) (net.Conn, error) {
	r := bufio.NewReader(conn)
	request := make([]byte, 1+primeSize+1)
	if _, err := io.ReadFull(r, request); err != nil {
		return nil, err
	}
	if _, err := io.ReadFull(r, make([]byte, request[1+primeSize])); err != nil {
		return nil, err
	}
	var secret [16]byte
	rand.Read(secret[:])
	b := new(big.Int).SetBytes(secret[:])
	shared := make([]byte, primeSize)
	new(big.Int).Exp(new(big.Int).SetBytes(request[1:1+primeSize]), b, dhPrime).FillBytes(shared)
	c := &cryptConn{Conn: conn, r: r, in: buildCipher(shared, magicRequester), out: buildCipher(shared, magicServer)}

	answer := make([]byte, primeSize)
	new(big.Int).Exp(big.NewInt(2), b, dhPrime).FillBytes(answer)
	tail := binary.LittleEndian.AppendUint32(nil, magicSync)
	tail = append(tail, 0, 0, 0)
	c.out.XORKeyStream(tail, tail)
	if _, err := conn.Write(append(answer, tail...)); err != nil {
		return nil, err
	}
	reply := make([]byte, 6)
	if _, err := io.ReadFull(c, reply); err != nil {
		return nil, err
	}
	if binary.LittleEndian.Uint32(reply) != magicSync {
		return nil, errHandshake
	}
	if _, err := io.ReadFull(c, make([]byte, reply[5])); err != nil {
		return nil, err
	}
	return c, nil
}

func buildCipher(shared []byte, magic byte) *rc4.Cipher {
	sum := md5.Sum(append(append([]byte(nil), shared...), magic))
	c, _ := rc4.NewCipher(sum[:])
	discard := make([]byte, 1024)
	c.XORKeyStream(discard, discard)
	return c
}

// The server side of aMule's obfuscated server UDP
// (EncryptedDatagramSocket.cpp:46-60, 393-484): <marker 1><key part 2>,
// then RC4 keyed with MD5(<key 4><direction 1><key part 2>), no discard,
// over <magic 4><padding length 1><padding><packet>.
const (
	udpSyncServer   uint32 = 0x13EF24D5
	udpClientServer byte   = 0x6B
	udpServerClient byte   = 0xA5
)

func buildUDPCipher(key uint32, direction byte, keyPart []byte) *rc4.Cipher {
	material := binary.LittleEndian.AppendUint32(nil, key)
	material = append(append(material, direction), keyPart...)
	sum := md5.Sum(material)
	c, _ := rc4.NewCipher(sum[:])
	return c
}

// openDatagram decrypts a client's datagram sent with key; false when it
// is not one.
func openDatagram(data []byte, key uint32) ([]byte, bool) {
	if len(data) < 8 {
		return nil, false
	}
	plain := make([]byte, len(data)-3)
	buildUDPCipher(key, udpClientServer, data[1:3]).XORKeyStream(plain, data[3:])
	padding := int(plain[4] & 0x0F)
	if binary.LittleEndian.Uint32(plain) != udpSyncServer || len(plain) < 5+padding {
		return nil, false
	}
	return plain[5+padding:], true
}

// sealDatagram encrypts a datagram for a client with key, padded with three
// bytes so that the client must skip padding; a non-zero marker is its first
// byte.
func sealDatagram(packet []byte, key uint32, marker byte) []byte {
	var head [3]byte
	rand.Read(head[:])
	if head[0] == 0xE3 {
		head[0] = 0x00
	}
	if marker != 0 {
		head[0] = marker
	}
	plain := binary.LittleEndian.AppendUint32(nil, udpSyncServer)
	plain = append(append(plain, 3, 7, 7, 7), packet...)
	sealed := make([]byte, len(plain))
	buildUDPCipher(key, udpServerClient, head[1:3]).XORKeyStream(sealed, plain)
	return append(head[:], sealed...)
}
