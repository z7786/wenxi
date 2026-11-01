// Package store loads and saves the Engine Process's Durable State.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const fileName = "state.json"

// Encode / Decode use the upstream versioned format for encrypted embedding.
func Encode(state State) ([]byte, error) { return json.Marshal(toFile(state)) }
func Decode(raw []byte) (State, error) {
	if len(raw) == 0 {
		return buildState(), nil
	}
	var header struct {
		Version int `json:"version"`
	}
	if err := json.Unmarshal(raw, &header); err != nil {
		return State{}, err
	}
	if header.Version != version {
		return State{}, fmt.Errorf("unsupported version %d", header.Version)
	}
	return parse(raw)
}

type State struct {
	Identity  Identity
	Kad       Kad
	Credits   map[wire.Hash]Credit
	Transfers map[wire.Hash]Transfer
	Servers   []Server
}

type Identity struct {
	UserHash wire.Hash
	// PrivateKey is the DER encoded RSA key for Secure User Identification;
	// empty until the engine creates one.
	PrivateKey []byte
}

type Kad struct {
	ID           wire.Hash
	IsFirewalled bool
	// UDPKey is the secret behind the verify keys of obfuscated Kad
	// datagrams; nodes that know it keep trusting us across restarts.
	UDPKey uint32
	Nodes  []KadNode
}

type KadNode struct {
	ID   wire.Hash
	Addr netip.AddrPort
	// TCPPort is kept because a loaded node verified by answering our
	// KADEMLIA2_REQ never tells it again, and would be handed out with TCP
	// port 0 in our contact answers.
	TCPPort uint16
	Version byte
}

// Server is what the Engine Process learned about one listed eD2k server,
// as aMule keeps it in its own server.met (ServerList.cpp:689-800). A
// server listed by address is named by Endpoint, one listed by host name
// by Host and Port.
type Server struct {
	Endpoint           netip.AddrPort
	Host               string
	Port               uint16
	Failures           uint32
	Ping               uint32
	Users              uint32
	Files              uint32
	SoftFiles          uint32
	UDPFlags           uint32
	TCPObfuscationPort uint16
	UDPObfuscationPort uint16
	PingedAt           time.Time
	// UDPKey and UDPKeyIP are saved as aMule saves ST_UDPKEY and
	// ST_UDPKEYIP: the key serves again while our public address is the
	// same (server.Entry).
	UDPKey   uint32
	UDPKeyIP netip.Addr
}

type Credit struct {
	Uploaded   uint64
	Downloaded uint64
	PublicKey  []byte
	LastSeen   time.Time
}

// Transfer is one file's download progress. WrittenBlocks are the blocks
// written to parts not yet verified; one cut off when the slot delivering it
// ended is its leading bytes, as aMule's .part.met gap list keeps them.
type Transfer struct {
	Size          int64
	File          string
	PartHashes    []wire.Hash
	VerifiedParts piece.Set
	WrittenBlocks []piece.Block
	Uploaded      uint64
	Created       time.Time
}

func buildState() State {
	return State{Credits: map[wire.Hash]Credit{}, Transfers: map[wire.Hash]Transfer{}}
}

// Load reads the state in folder. A missing file is an empty State; a file
// written by goed2k is converted.
func Load(folder string) (State, error) {
	raw, err := os.ReadFile(filepath.Join(folder, fileName))
	if errors.Is(err, fs.ErrNotExist) {
		return buildState(), nil
	}
	if err != nil {
		return State{}, err
	}
	var header struct {
		Version int `json:"version"`
	}
	if err := json.Unmarshal(raw, &header); err != nil {
		return State{}, fmt.Errorf("load %s: %w", fileName, err)
	}
	var state State
	switch header.Version {
	case 0, 1, 2, 3:
		state, err = parseGoed2k(raw)
	case version:
		state, err = parse(raw)
	default:
		err = fmt.Errorf("unsupported version %d", header.Version)
	}
	if err != nil {
		return State{}, fmt.Errorf("load %s: %w", fileName, err)
	}
	return state, nil
}

// Save replaces the state in folder so that a crash leaves either the old or
// the new file, never a torn one.
func Save(folder string, state State) error {
	raw, err := json.MarshalIndent(toFile(state), "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return err
	}
	temp, err := os.CreateTemp(folder, fileName+".*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	_, err = temp.Write(raw)
	if err == nil {
		err = temp.Sync()
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(temp.Name(), filepath.Join(folder, fileName)); err != nil {
		return err
	}
	return flushFolder(folder)
}

// flushFolder makes the rename durable. Windows cannot open a directory for
// flushing; NTFS journals the rename instead.
func flushFolder(folder string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	dir, err := os.Open(folder)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
