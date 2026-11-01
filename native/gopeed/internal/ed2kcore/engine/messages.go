package engine

import (
	"io"
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/disk"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/server"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// RunID is chosen by Kelpie and never reused within one Engine Process.
type RunID uint64

type Mode int

const (
	ModeDownload Mode = iota
	ModeSeed
)

// Command is posted to the Engine by the gateway; see docs/protocol.md.
type Command interface{ isCommand() }

type RunCommand struct {
	ID   RunID
	Mode Mode
	Link string
	File string
}

type StopCommand struct{ ID RunID }

type RemoveCommand struct{ Hash wire.Hash }
type CheckpointCommand struct{ Reply chan<- error }

// Settings are the part of Config that a posted Settings changes while
// the engine runs.
type Settings struct {
	EnableKad  bool
	EnableUPnP bool
	// DownloadLimit and UploadLimit are bytes per second; 0 is unlimited.
	DownloadLimit, UploadLimit int64
	// Proxy is a socks5:// or socks5h:// URL, or "" to go direct (ADR-0006).
	Proxy string
}

func (RunCommand) isCommand()        {}
func (StopCommand) isCommand()       {}
func (RemoveCommand) isCommand()     {}
func (CheckpointCommand) isCommand() {}
func (Settings) isCommand()          {}

type Config struct {
	// Optional embedding hooks; nil retains the standalone engine behavior.
	Disk        disk.Disk
	LoadState   func() (store.State, error)
	SaveState   func(store.State) error
	Servers     []server.Entry
	Version     string
	DataFolder  string
	Port        int
	ServerLists []string
	NodeLists   []string
	TraceFile   string
	Settings
	// PacketLog, when set, gets one line per TCP packet sent or received
	// and per closed connection, for debugging against real peers.
	PacketLog io.Writer
	// LocalAddrs are the host's interface addresses at start, which tell
	// our own address apart in a source list.
	LocalAddrs []netip.Addr
}

type Progress struct {
	Hash            wire.Hash
	Size            int64
	Received        int64
	NetworkReceived int64
	DownloadRate    int64
	UploadRate      int64
	Uploaded        int64
	Peers           int
	ActivePeers     int
	// HeldSources, HeldUntil and Sources follow docs/protocol.md "progress".
	HeldSources int
	HeldUntil   time.Time
	Sources     []Source
}

// Source is one source in Progress.Sources.
type Source struct {
	Address      string
	Software     string
	Status       string
	Rank         int
	DownloadRate int64
	Channel      string
}

type Network struct {
	IsServerConnected bool
	IsHighID          bool
	IsKadFirewalled   bool
	KadNodes          int
	// IsBehindCarrierNat follows docs/protocol.md "network".
	IsBehindCarrierNat bool
	// ProxyIssue is "", "unreachable" or "noUdp", as docs/protocol.md
	// "network" says.
	ProxyIssue string
}

// Code is why a Run failed; the gateway names it on the wire
// (docs/protocol.md "Error codes").
type Code int

const (
	CodeInternal Code = iota
	CodeInvalidLink
	CodeOutputExists
	CodeTransferBusy
	CodeDiskFull
	CodeFileError
	CodeStartFailed
)

type Error struct {
	Code    Code
	Message string
}

func (e *Error) Error() string { return e.Message }

// Events is how the Engine reports to the gateway. Implementations must never
// block: progress and network are latest-value slots, and every run gets
// exactly one SendEnded (ADR-0005).
type Events interface {
	SetProgress(id RunID, progress Progress)
	SendEnded(id RunID, err *Error)
	SetNetwork(network Network)
}
