package obfuscation

import (
	"crypto/md5"
	"crypto/rc4"
	"encoding/binary"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// Kad datagram obfuscation, aMule EncryptedDatagramSocket.cpp: after an
// unencrypted marker byte and a 2-byte key part comes, RC4-encrypted
// without discarding keystream, <magic 4><padding length 1><padding>
// <receiver verify key 4><sender verify key 4><packet>. The key is the MD5
// of the receiver's node ID or of the receiver verify key, each followed by
// the key part. The marker's two low bits say which (00 node ID, 10
// receiver key); 01 marks eD2k datagrams, which Kad does not read.
const (
	magicUDPSync uint32 = 0x395F2EC1 // MAGICVALUE_UDP_SYNC_CLIENT
	kadHeader           = 16         // CRYPT_HEADER_WITHOUTPADDING plus the two verify keys
)

// KadDatagram is a Kad packet with the verify keys it travels with. A
// receiver verify key proves the sender heard from us before; the sender
// verify key is what the receiver should encrypt its answers with.
type KadDatagram struct {
	Packet      []byte
	ReceiverKey uint32
	SenderKey   uint32
}

// BuildKadDatagram encrypts d with the receiver's node ID in Kad wire form
// when nodeID is not nil, else with d.ReceiverKey. random supplies the key
// part and the marker.
func BuildKadDatagram(d KadDatagram, nodeID []byte, random uint32) []byte {
	keyPart := binary.LittleEndian.AppendUint16(nil, uint16(random))
	marker := byte(random>>16) &^ 0x03
	key := nodeID
	if nodeID == nil {
		marker |= 0x02
		key = binary.LittleEndian.AppendUint32(nil, d.ReceiverKey)
	}
	for matchPlainDatagram(marker) {
		marker += 0x04
	}
	packet := binary.LittleEndian.AppendUint32(nil, d.ReceiverKey)
	packet = binary.LittleEndian.AppendUint32(packet, d.SenderKey)
	return buildDatagram(marker, keyPart, buildDatagramCipher(key, keyPart), magicUDPSync, append(packet, d.Packet...))
}

// ParseKadDatagram decrypts a Kad datagram addressed to the node nodeID
// (Kad wire form) whose verify key for the sender is receiverKey. It
// reports false for plain datagrams and anything not encrypted for Kad.
func ParseKadDatagram(data, nodeID []byte, receiverKey uint32) (KadDatagram, bool) {
	if len(data) <= kadHeader || matchPlainDatagram(data[0]) {
		return KadDatagram{}, false
	}
	for _, key := range [][]byte{nodeID, binary.LittleEndian.AppendUint32(nil, receiverKey)} {
		rest, ok := parseDatagram(data, buildDatagramCipher(key, data[1:3]), magicUDPSync, 0xFF)
		if !ok {
			continue
		}
		if len(rest) <= 8 {
			return KadDatagram{}, false
		}
		return KadDatagram{
			ReceiverKey: binary.LittleEndian.Uint32(rest),
			SenderKey:   binary.LittleEndian.Uint32(rest[4:]),
			Packet:      rest[8:],
		}, true
	}
	return KadDatagram{}, false
}

// BuildKadVerifyKey is CPrefs::GetUDPVerifyKey: the key we expect back
// from ip, derived from our secret so that it needs no table.
func BuildKadVerifyKey(secret uint32, ip netip.Addr) uint32 {
	buf := binary.LittleEndian.AppendUint32(nil, wire.ToClientID(ip))
	sum := md5.Sum(binary.LittleEndian.AppendUint32(buf, secret))
	x := binary.LittleEndian.Uint32(sum[0:]) ^ binary.LittleEndian.Uint32(sum[4:]) ^
		binary.LittleEndian.Uint32(sum[8:]) ^ binary.LittleEndian.Uint32(sum[12:])
	return x%0xFFFFFFFE + 1
}

// buildDatagramCipher keys RC4 with the MD5 of the key parts in order.
// Datagrams keep the whole keystream (EncryptedDatagramSocket.cpp:34).
func buildDatagramCipher(parts ...[]byte) *rc4.Cipher {
	h := md5.New()
	for _, part := range parts {
		h.Write(part)
	}
	c, _ := rc4.NewCipher(h.Sum(nil))
	return c
}

// matchPlainDatagram tells whether a first byte is a protocol byte, which
// an obfuscated datagram's marker never is.
func matchPlainDatagram(b byte) bool {
	switch b {
	case wire.ProtocolEMule, wire.ProtocolKad, wire.ProtocolKadPacked, wire.ProtocolPacked, 0xA3, 0xB2:
		return true
	}
	return false
}
