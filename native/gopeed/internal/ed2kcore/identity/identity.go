// Package identity implements eMule Secure User Identification (SUI) and the
// credits ledger. It does no I/O.
//
// Handshake, as eMule and aMule run it on each peer connection once both hello
// packets are in: each side whose peer advertised SUI support sends
// OP_SECIDENTSTATE with a fresh nonzero challenge, asking for
// stateKeyAndSignatureNeeded when it knows no public key for the peer's user
// hash and stateSignatureNeeded otherwise. The receiver answers per
// BuildReply: OP_PUBLICKEY if asked, then OP_SIGNATURE over the asker's public
// key and challenge. A signature that cannot be built yet because the asker's
// key has not arrived is sent when OP_PUBLICKEY arrives. The asker checks the
// signature with MatchSignature and reports the outcome to the Ledger.
package identity

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// Support is the SecIdent bit set advertised in hello misc options:
// bit 0 = signature v1, bit 1 = signature v2.
const Support = 3

// State is the request carried by OP_SECIDENTSTATE.
type State byte

const (
	stateNone                  State = 0
	stateSignatureNeeded       State = 1
	stateKeyAndSignatureNeeded State = 2
)

// IPKind tells the verifier which IPv4 address the signer appended to the
// signed message (signature v2). Zero means v1: no address appended.
type IPKind byte

const (
	ipKindNone IPKind = 0
	// ipKindVerifier: the signer did not know its own address (LowID), so it
	// signed the verifier's address as the signer sees it.
	ipKindVerifier IPKind = 10
	// ipKindSigner: the signer signed its own server-assigned HighID address.
	ipKindSigner IPKind = 20
	// ipKindZero: the signed address is 0.0.0.0.
	ipKindZero IPKind = 30
)

// Challenge is everything besides the verifier's public key that the
// signature covers: Value is the 4-byte random challenge from
// OP_SECIDENTSTATE, and IPKind names which address, if any, is appended.
// Both sides fill in the same roles: SignerIP is the signer's
// server-assigned address, VerifierIP the verifier's address as the signer
// sees it.
type Challenge struct {
	Value      uint32
	IPKind     IPKind
	SignerIP   netip.Addr
	VerifierIP netip.Addr
}

func (c Challenge) ip() netip.Addr {
	switch c.IPKind {
	case ipKindSigner:
		return c.SignerIP
	case ipKindVerifier:
		return c.VerifierIP
	}
	return netip.Addr{}
}

// buildMessage lays out what is signed: verifier's public key || challenge
// (uint32 LE) [|| IPv4 octets in network order || kind]. eMule pokes its
// network-order IP as a little-endian uint32, which yields the octets as-is.
func buildMessage(verifierKey []byte, challenge Challenge) []byte {
	message := binary.LittleEndian.AppendUint32(append([]byte(nil), verifierKey...), challenge.Value)
	if challenge.IPKind == ipKindNone {
		return message
	}
	var ip [4]byte
	if addr := challenge.ip(); addr.Is4() {
		ip = addr.As4()
	}
	return append(append(message, ip[:]...), byte(challenge.IPKind))
}

// Self is our own identity: the user hash and the SUI key pair.
type Self struct {
	UserHash wire.Hash
	key      privateKey
}

// IsEmuleHash tells whether bytes 5 and 14 of a user hash carry eMule's
// marker (aMule GetHashType, BaseClient.cpp:1743).
func IsEmuleHash(hash wire.Hash) bool { return hash[5] == 14 && hash[14] == 111 }

// CreateSelf makes a new random user hash, marked as an eMule hash, and a new
// 384-bit key pair.
func CreateSelf() (Self, error) {
	var hash wire.Hash
	if _, err := rand.Read(hash[:]); err != nil {
		return Self{}, err
	}
	hash[5], hash[14] = 14, 111
	key, err := createKey()
	if err != nil {
		return Self{}, err
	}
	return Self{hash, key}, nil
}

// LoadSelf rebuilds Self from a user hash and a PKCS#1 DER private key, as
// produced by PrivateKey.
func LoadSelf(userHash wire.Hash, keyDER []byte) (Self, error) {
	key, err := parsePKCS1(keyDER)
	if err != nil {
		return Self{}, err
	}
	if len(toSubjectPublicKeyInfo(key.publicKey)) > maxKeySize {
		return Self{}, errors.New("private key: public key too large for OP_PUBLICKEY")
	}
	return Self{userHash, key}, nil
}

// PublicKey is our key as sent in OP_PUBLICKEY: X.509 SubjectPublicKeyInfo DER.
func (s Self) PublicKey() []byte {
	return toSubjectPublicKeyInfo(s.key.publicKey)
}

// PrivateKey is the PKCS#1 DER form that LoadSelf reads.
func (s Self) PrivateKey() []byte {
	return toPKCS1(s.key)
}

// BuildSignature signs peerKey and challenge for OP_SIGNATURE (RSASSA-PKCS1-v1_5
// with SHA-1).
func (s Self) BuildSignature(peerKey []byte, challenge Challenge) []byte {
	return buildPKCS1v15Signature(s.key, buildMessage(peerKey, challenge))
}

// MatchSignature reports whether signature, made by the holder of peerKey,
// covers ourKey and challenge.
func MatchSignature(peerKey, signature, ourKey []byte, challenge Challenge) bool {
	key, err := parseSubjectPublicKeyInfo(peerKey)
	if err != nil {
		return false
	}
	return matchPKCS1v15Signature(key, buildMessage(ourKey, challenge), signature)
}

// Reply is what to send after receiving OP_SECIDENTSTATE. A signature
// needs the peer's key; without it, it is sent once OP_PUBLICKEY arrives.
type Reply struct {
	ShouldSendKey bool
	ShouldSign    bool
	IPKind        IPKind
}

// BuildReply follows eMule: signatures are v1 unless the peer supports only
// v2; a v2 signer that is LowID does not know its own address and signs the
// peer's instead.
func BuildReply(state State, peerSupport byte, isLowID bool) Reply {
	if state != stateSignatureNeeded && state != stateKeyAndSignatureNeeded {
		return Reply{}
	}
	reply := Reply{ShouldSendKey: state == stateKeyAndSignatureNeeded, ShouldSign: true}
	if peerSupport&1 == 0 {
		reply.IPKind = ipKindSigner
		if isLowID {
			reply.IPKind = ipKindVerifier
		}
	}
	return reply
}
