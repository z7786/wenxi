package wire

import (
	"encoding/base32"
	"encoding/hex"
	"fmt"
	"strings"
)

// Hash is an MD4 digest: a file hash, a part hash, or a user hash.
type Hash [16]byte

func ParseHash(text string) (Hash, error) {
	var hash Hash
	if len(text) != 32 {
		return hash, fmt.Errorf("hash %q: want 32 hex digits", text)
	}
	if _, err := hex.Decode(hash[:], []byte(text)); err != nil {
		return hash, fmt.Errorf("hash %q: %w", text, err)
	}
	return hash, nil
}

func (h Hash) String() string {
	return strings.ToUpper(hex.EncodeToString(h[:]))
}

// AICHHash is a SHA-1 digest in a file's AICH hash tree.
type AICHHash [20]byte

// aichEncoding is aMule's EncodeBase32: RFC 4648 without padding.
var aichEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

func ParseAICHHash(text string) (AICHHash, error) {
	var hash AICHHash
	if len(text) != 32 {
		return hash, fmt.Errorf("AICH hash %q: want 32 base32 digits", text)
	}
	decoded, err := aichEncoding.DecodeString(strings.ToUpper(text))
	if err != nil {
		return hash, fmt.Errorf("AICH hash %q: want 32 base32 digits", text)
	}
	copy(hash[:], decoded)
	return hash, nil
}

func (h AICHHash) String() string {
	return aichEncoding.EncodeToString(h[:])
}
