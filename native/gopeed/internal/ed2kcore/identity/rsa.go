package identity

import (
	"bytes"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/asn1"
	"errors"
	"fmt"
	"math/big"
)

// eMule keys are 384-bit RSA with Crypto++'s default exponent. Go's crypto/rsa
// refuses keys under 1024 bits, so key generation, PKCS#1 v1.5 signing and
// verification are done here with math/big. A 384-bit key offers no secrecy
// worth timing-attack hardening; it only binds credits to a user hash.
const (
	keyBits        = 384
	publicExponent = 17
	maxKeySize     = 80
)

var (
	oidRSA         = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 1}
	sha1DigestInfo = []byte{0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14}
	one            = big.NewInt(1)
)

// publicKey is also the PKCS#1 RSAPublicKey ASN.1 layout.
type publicKey struct {
	N *big.Int
	E int
}

type privateKey struct {
	publicKey
	D, P, Q *big.Int
}

type pkcs1PrivateKey struct {
	Version int
	N       *big.Int
	E       int
	D       *big.Int
	P       *big.Int
	Q       *big.Int
	Dp      *big.Int
	Dq      *big.Int
	Qinv    *big.Int
}

type algorithmIdentifier struct {
	Algorithm  asn1.ObjectIdentifier
	Parameters asn1.RawValue
}

type subjectPublicKeyInfo struct {
	Algorithm algorithmIdentifier
	PublicKey asn1.BitString
}

func createKey() (privateKey, error) {
	e := big.NewInt(publicExponent)
	for {
		p, err := rand.Prime(rand.Reader, keyBits/2)
		if err != nil {
			return privateKey{}, err
		}
		q, err := rand.Prime(rand.Reader, keyBits/2)
		if err != nil {
			return privateKey{}, err
		}
		n := new(big.Int).Mul(p, q)
		if p.Cmp(q) == 0 || n.BitLen() != keyBits {
			continue
		}
		d := new(big.Int).ModInverse(e, lcmMinusOne(p, q))
		if d == nil {
			continue
		}
		return privateKey{publicKey{n, publicExponent}, d, p, q}, nil
	}
}

func lcmMinusOne(p, q *big.Int) *big.Int {
	p1 := new(big.Int).Sub(p, one)
	q1 := new(big.Int).Sub(q, one)
	gcd := new(big.Int).GCD(nil, nil, p1, q1)
	return new(big.Int).Div(new(big.Int).Mul(p1, q1), gcd)
}

func toPKCS1(key privateKey) []byte {
	dp := new(big.Int).Mod(key.D, new(big.Int).Sub(key.P, one))
	dq := new(big.Int).Mod(key.D, new(big.Int).Sub(key.Q, one))
	qinv := new(big.Int).ModInverse(key.Q, key.P)
	der, err := asn1.Marshal(pkcs1PrivateKey{0, key.N, key.E, key.D, key.P, key.Q, dp, dq, qinv})
	if err != nil {
		panic(err)
	}
	return der
}

func parsePKCS1(der []byte) (privateKey, error) {
	var raw pkcs1PrivateKey
	rest, err := asn1.Unmarshal(der, &raw)
	if err != nil {
		return privateKey{}, fmt.Errorf("private key: %w", err)
	}
	if len(rest) != 0 || raw.Version != 0 {
		return privateKey{}, errors.New("private key: not a two-prime PKCS#1 key")
	}
	if raw.E < 3 || raw.P.Sign() <= 0 || raw.Q.Sign() <= 0 || new(big.Int).Mul(raw.P, raw.Q).Cmp(raw.N) != 0 {
		return privateKey{}, errors.New("private key: inconsistent primes")
	}
	ed := new(big.Int).Mul(big.NewInt(int64(raw.E)), raw.D)
	if new(big.Int).Mod(ed, lcmMinusOne(raw.P, raw.Q)).Cmp(one) != 0 {
		return privateKey{}, errors.New("private key: inconsistent exponents")
	}
	return privateKey{publicKey{raw.N, raw.E}, raw.D, raw.P, raw.Q}, nil
}

func toSubjectPublicKeyInfo(key publicKey) []byte {
	inner, err := asn1.Marshal(key)
	if err != nil {
		panic(err)
	}
	der, err := asn1.Marshal(subjectPublicKeyInfo{
		Algorithm: algorithmIdentifier{oidRSA, asn1.NullRawValue},
		PublicKey: asn1.BitString{Bytes: inner, BitLength: 8 * len(inner)},
	})
	if err != nil {
		panic(err)
	}
	return der
}

// parseSubjectPublicKeyInfo accepts only the canonical DER encoding, so one
// key has exactly one byte form and stored keys compare with bytes.Equal.
func parseSubjectPublicKeyInfo(der []byte) (publicKey, error) {
	if len(der) > maxKeySize {
		return publicKey{}, fmt.Errorf("public key: %d bytes, max %d", len(der), maxKeySize)
	}
	var info subjectPublicKeyInfo
	rest, err := asn1.Unmarshal(der, &info)
	if err != nil {
		return publicKey{}, fmt.Errorf("public key: %w", err)
	}
	if len(rest) != 0 || !info.Algorithm.Algorithm.Equal(oidRSA) {
		return publicKey{}, errors.New("public key: not RSA")
	}
	var key publicKey
	rest, err = asn1.Unmarshal(info.PublicKey.RightAlign(), &key)
	if err != nil {
		return publicKey{}, fmt.Errorf("public key: %w", err)
	}
	if len(rest) != 0 || key.N.Sign() <= 0 || key.E < 3 || !bytes.Equal(toSubjectPublicKeyInfo(key), der) {
		return publicKey{}, errors.New("public key: not canonical DER")
	}
	return key, nil
}

func buildEncodedDigest(message []byte, size int) []byte {
	digest := sha1.Sum(message)
	encoded := make([]byte, size)
	encoded[1] = 0x01
	tail := size - len(sha1DigestInfo) - len(digest)
	for i := 2; i < tail-1; i++ {
		encoded[i] = 0xff
	}
	copy(encoded[tail:], sha1DigestInfo)
	copy(encoded[tail+len(sha1DigestInfo):], digest[:])
	return encoded
}

func (key publicKey) size() int {
	return (key.N.BitLen() + 7) / 8
}

func buildPKCS1v15Signature(key privateKey, message []byte) []byte {
	size := key.size()
	m := new(big.Int).SetBytes(buildEncodedDigest(message, size))
	return new(big.Int).Exp(m, key.D, key.N).FillBytes(make([]byte, size))
}

func matchPKCS1v15Signature(key publicKey, message, signature []byte) bool {
	size := key.size()
	if size < len(sha1DigestInfo)+sha1.Size+11 || len(signature) != size {
		return false
	}
	s := new(big.Int).SetBytes(signature)
	if s.Cmp(key.N) >= 0 {
		return false
	}
	m := new(big.Int).Exp(s, big.NewInt(int64(key.E)), key.N)
	return subtle.ConstantTimeCompare(m.FillBytes(make([]byte, size)), buildEncodedDigest(message, size)) == 1
}
