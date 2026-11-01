package link

import (
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// errInvalid starts every Parse error: the text is not an eD2k file link.
var errInvalid = errors.New("invalid ed2k file link")

// maxSize is eMule's MAX_EMULE_FILE_SIZE (256 GiB).
const maxSize int64 = 256 << 30

// File is what an eD2k file link says about a file. PartHashes is empty unless
// the link carries a hash set that matches the file hash; AICHHash is zero
// unless the link carries one; Sources holds only the sources given as
// IP:port.
type File struct {
	Name       string
	Size       int64
	Hash       wire.Hash
	PartHashes []wire.Hash
	AICHHash   wire.AICHHash
	Sources    []netip.AddrPort
}

// Parse reads ed2k://|file|<name>|<size>|<hash>|[h=<AICH>|][p=<hashes>|]/[|sources,<ip:port>,...|/].
// Unknown fields and HTTP sources are ignored.
func Parse(text string) (File, error) {
	text = strings.TrimSpace(text)
	if len(text) > 64*1024 {
		return File{}, fmt.Errorf("%w: too long", errInvalid)
	}
	const scheme = "ed2k://"
	if len(text) < len(scheme) || !strings.EqualFold(text[:len(scheme)], scheme) {
		return File{}, fmt.Errorf("%w: missing ed2k:// scheme", errInvalid)
	}
	body := text[len(scheme):]
	// Browsers may encode every separator, as aMule's TextClient.cpp:537-540
	// repairs. Only such a link is decoded: in a plain link %7C is part of
	// the name.
	if len(body) >= 3 && strings.EqualFold(body[:3], "%7C") {
		body = strings.ReplaceAll(strings.ReplaceAll(body, "%7C", "|"), "%7c", "|")
	}
	fields := strings.Split(body, "|")
	if len(fields) < 6 || fields[0] != "" || !strings.EqualFold(fields[1], "file") || fields[len(fields)-1] != "/" {
		return File{}, fmt.Errorf("%w: not a file link", errInvalid)
	}

	name, err := url.PathUnescape(fields[2])
	if err != nil || !utf8.ValidString(name) {
		return File{}, fmt.Errorf("%w: bad name encoding", errInvalid)
	}
	file := File{Name: name}
	if file.Name == "" || strings.ContainsFunc(file.Name, unicode.IsControl) {
		return File{}, fmt.Errorf("%w: empty name", errInvalid)
	}
	size, err := parseSize(fields[3])
	if err != nil {
		return File{}, err
	}
	file.Size = size
	if file.Hash, err = wire.ParseHash(fields[4]); err != nil {
		return File{}, fmt.Errorf("%w: %w", errInvalid, err)
	}

	for _, field := range fields[5:] {
		if strings.ContainsFunc(field, func(r rune) bool { return unicode.IsControl(r) || unicode.IsSpace(r) }) {
			return File{}, fmt.Errorf("%w: invalid extension", errInvalid)
		}
		switch {
		case strings.HasPrefix(field, "p="):
			file.PartHashes = parsePartHashes(field[len("p="):], file.Size, file.Hash)
		case strings.HasPrefix(field, "h="):
			// aMule rejects the link over a malformed AICH hash
			// (ED2KLink.cpp:260-267); like a bad hash set, it is only dropped.
			file.AICHHash, _ = wire.ParseAICHHash(field[len("h="):])
		case strings.HasPrefix(strings.ToLower(field), "sources,"):
			file.Sources = append(file.Sources, parseSources(field)...)
		}
	}
	return file, nil
}

func parseSize(text string) (int64, error) {
	if text == "" || strings.Trim(text, "0123456789") != "" {
		return 0, fmt.Errorf("%w: size %q is not a decimal number", errInvalid, text)
	}
	size, err := strconv.ParseInt(text, 10, 64)
	if err != nil || size <= 0 || size > maxSize {
		return 0, fmt.Errorf("%w: size %q is not between 1 and %d", errInvalid, text, maxSize)
	}
	return size, nil
}

// parsePartHashes drops a hash set that does not belong to the file rather
// than rejecting the link: the file hash alone is enough to download.
func parsePartHashes(text string, size int64, fileHash wire.Hash) []wire.Hash {
	var hashes []wire.Hash
	for _, item := range strings.Split(text, ":") {
		hash, err := wire.ParseHash(item)
		if err != nil {
			return nil
		}
		hashes = append(hashes, hash)
	}
	if len(hashes) != piece.HashCount(size) || piece.BuildFileHash(hashes) != fileHash {
		return nil
	}
	return hashes
}

// parseSources skips host names: resolving them is I/O and eMule rarely
// writes them.
func parseSources(field string) []netip.AddrPort {
	var sources []netip.AddrPort
	for _, item := range strings.Split(field, ",")[1:] {
		source, err := netip.ParseAddrPort(strings.TrimSpace(item))
		if err == nil && source.Port() != 0 {
			sources = append(sources, source)
		}
	}
	return sources
}

// toUnescaped decodes %XX escapes like Python's urllib.parse.unquote, so both
// sides of testdata/links.json agree: a malformed escape stays literal and '+'
// stays a plus.
func toUnescaped(text string) string {
	var decoded []byte
	for i := 0; i < len(text); i++ {
		if text[i] == '%' && i+2 < len(text) && isHex(text[i+1]) && isHex(text[i+2]) {
			value, _ := strconv.ParseUint(text[i+1:i+3], 16, 8)
			decoded = append(decoded, byte(value))
			i += 2
			continue
		}
		decoded = append(decoded, text[i])
	}
	return strings.ToValidUTF8(string(decoded), "\uFFFD")
}

func isHex(c byte) bool {
	return '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F'
}
