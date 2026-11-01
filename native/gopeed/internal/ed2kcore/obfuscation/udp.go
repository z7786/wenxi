package obfuscation

import (
	"crypto/rc4"
	"encoding/binary"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// eD2k datagram obfuscation, aMule EncryptedDatagramSocket.cpp:26-75: an
// unencrypted marker byte and 2-byte key part, then, RC4-encrypted,
// <magic 4><padding length 1><padding><packet>. Between clients the key is
// the MD5 of the receiver's user hash, the sender's public IPv4 address,
// magicUDP and the key part; with a server, of the server's base key, the
// direction's magic and the key part. Kelpie never pads.
const (
	magicUDP           byte   = 91         // MAGICVALUE_UDP
	magicUDPSyncServer uint32 = 0x13EF24D5 // MAGICVALUE_UDP_SYNC_SERVER
	magicServerClient  byte   = 0xA5       // MAGICVALUE_UDP_SERVERCLIENT
	magicClientServer  byte   = 0x6B       // MAGICVALUE_UDP_CLIENTSERVER
	datagramHeader            = 8          // CRYPT_HEADER_WITHOUTPADDING
)

// BuildPeerDatagram encrypts packet for the client whose user hash is
// user; senderIP is our public IPv4 address. random supplies the key part
// and the marker, whose low bit is set for eD2k (:312-345).
func BuildPeerDatagram(packet []byte, user wire.Hash, senderIP netip.Addr, random uint32) []byte {
	keyPart := binary.LittleEndian.AppendUint16(nil, uint16(random))
	marker := byte(random>>16) | 0x01
	for matchPlainDatagram(marker) {
		marker += 0x02
	}
	ip := senderIP.As4()
	cipher := buildDatagramCipher(user[:], ip[:], []byte{magicUDP}, keyPart)
	return buildDatagram(marker, keyPart, cipher, magicUDPSync, packet)
}

// ParsePeerDatagram decrypts a datagram the client at senderIP sent to us,
// whose user hash is self. It reports false for plain datagrams and for
// those not encrypted that way, which the caller reads as they came, as
// aMule does (:142-150, :233-235).
func ParsePeerDatagram(data []byte, self wire.Hash, senderIP netip.Addr) ([]byte, bool) {
	if len(data) <= datagramHeader || matchPlainDatagram(data[0]) {
		return nil, false
	}
	ip := senderIP.As4()
	cipher := buildDatagramCipher(self[:], ip[:], []byte{magicUDP}, data[1:3])
	return parseDatagram(data, cipher, magicUDPSync, 0xFF)
}

// BuildServerDatagram encrypts packet for a server whose UDP key is key.
func BuildServerDatagram(packet []byte, key uint32, random uint32) []byte {
	keyPart := binary.LittleEndian.AppendUint16(nil, uint16(random))
	marker := byte(random >> 16)
	if marker == wire.ProtocolEDonkey {
		marker++
	}
	cipher := buildDatagramCipher(binary.LittleEndian.AppendUint32(nil, key), []byte{magicClientServer}, keyPart)
	return buildDatagram(marker, keyPart, cipher, magicUDPSyncServer, packet)
}

// ParseServerDatagram decrypts a datagram from a server whose UDP key, or
// the challenge of an obfuscated ping, is key; it reports false like
// ParsePeerDatagram. A server's padding length counts modulo 16 (:409).
func ParseServerDatagram(data []byte, key uint32) ([]byte, bool) {
	if len(data) <= datagramHeader || data[0] == wire.ProtocolEDonkey {
		return nil, false
	}
	cipher := buildDatagramCipher(binary.LittleEndian.AppendUint32(nil, key), []byte{magicServerClient}, data[1:3])
	return parseDatagram(data, cipher, magicUDPSyncServer, 0x0F)
}

func buildDatagram(marker byte, keyPart []byte, cipher *rc4.Cipher, magic uint32, packet []byte) []byte {
	body := binary.LittleEndian.AppendUint32(nil, magic)
	body = append(body, 0)
	body = append(body, packet...)
	cipher.XORKeyStream(body, body)
	return append(append([]byte{marker}, keyPart...), body...)
}

func parseDatagram(data []byte, cipher *rc4.Cipher, magic uint32, paddingMask byte) ([]byte, bool) {
	var head [5]byte
	cipher.XORKeyStream(head[:], data[3:datagramHeader])
	if binary.LittleEndian.Uint32(head[:]) != magic {
		return nil, false
	}
	rest := append([]byte(nil), data[datagramHeader:]...)
	padding := int(head[4] & paddingMask)
	if len(rest) <= padding {
		return nil, false
	}
	cipher.XORKeyStream(rest, rest)
	return rest[padding:], true
}
