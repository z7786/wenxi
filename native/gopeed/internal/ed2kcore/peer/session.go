// Package peer is the state machine of one TCP connection to another eD2k
// client. One connection may download several of our files and upload
// several of theirs at once. It does no I/O: the engine feeds it packets,
// ticks and decisions, and performs the Output it returns.
package peer

import (
	"math/rand/v2"
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/identity"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

const (
	// CONNECTION_TIMEOUT: a connection with no packet either way for this
	// long is dead.
	connectionTimeout = 40 * time.Second
	// DOWNLOADTIMEOUT: a granted slot with blocks in flight but no data for
	// this long is given up.
	downloadTimeout = 100 * time.Second
)

// Config is our side of the connection, fixed for the session's lifetime:
// what our handshake tells the peer, and what we offer it.
type Config struct {
	Self identity.Self
	// Version is Kelpie's "major.minor.update".
	Version string
	// ClientID is the ID our Hello names, as aMule's GetID picks it: a
	// HighID, a LowID, 1 while only a firewalled Kad is connected, 0 with
	// neither server nor Kad.
	ClientID uint32
	// PublicIP is our IPv4 address as the world sees it, if known.
	PublicIP   netip.Addr
	Port       uint16
	UDPPort    uint16
	KadPort    uint16
	KadVersion byte
	Server     netip.AddrPort
	Random     *rand.Rand
	// Buddy is our Kad buddy's IP and UDP port while it serves us.
	Buddy netip.AddrPort
	// HasDirectCallback: we take Kad callback requests ourselves, over UDP.
	HasDirectCallback bool
	// ShareByHash looks up a file we offer.
	ShareByHash func(file wire.Hash) (Share, bool)
	// SourcesByHash names other peers that have file, for a Source Exchange
	// answer; parts is what the asking peer said it has of file, nil when it
	// did not say.
	SourcesByHash func(file wire.Hash, parts piece.Set) []Source
	// CanAskSlot tells whether the client user may be asked for an upload
	// slot for file now: the engine's A4AF rules, as a client counts every
	// ask as aggressive whatever file it names.
	CanAskSlot func(user, file wire.Hash) bool
}

// Capabilities is what the peer told us about itself in the handshake.
type Capabilities struct {
	UserHash wire.Hash
	// ClientID is the peer's LowID, 0 when it is a HighID.
	ClientID   uint32
	Port       uint16
	Server     netip.AddrPort
	UDPPort    uint16
	KadPort    uint16
	UDPVersion byte
	KadVersion byte
	// IPv6 is the public IPv6 address the peer announced, if any.
	IPv6 netip.Addr
	// MuleVersion is aMule's m_byEmuleVersion: 0x99 when Hello carried
	// CT_EMULE_VERSION, else the OP_EMULEINFO version byte, else 0
	// (BaseClient.cpp:631,884).
	MuleVersion        byte
	HasSourceExchange2 bool
	// HasDirectCallback: the peer takes callback requests over UDP at its
	// Kad port.
	HasDirectCallback bool
	// CryptOptions is the peer's obfuscation setting from its Hello, in
	// Source's layout.
	CryptOptions byte
	// Software names the peer's client and version, such as "eMule 0.70b";
	// "" when it does not tell.
	Software string
}

// features are the peer's protocol extensions that only decide the shape of
// the packets the session builds.
type features struct {
	// isEmule: the peer speaks the eMule extended protocol (CT_EMULE_VERSION
	// in Hello or OP_EMULEINFO).
	isEmule                    bool
	canCompress                bool
	secureIdent                byte
	extendedRequests           byte
	hasMultiPacket             bool
	hasExtMultiPacket          bool
	hasFileIdentifiers         bool
	hasLargeFiles              bool
	hasExtendedSources         bool
	hasExtendedSourcesSkipTags bool
	hasAICH                    bool
}

type Session struct {
	cfg        Config
	remote     netip.AddrPort
	greeting   greeting
	caps       Capabilities
	features   features
	lastActive time.Time
	timeout    time.Duration
	// earlyEmuleInfo is an OP_EMULEINFO that came before the peer's Hello.
	earlyEmuleInfo *client.EmuleInfo
	recovery       *recoveryRequest

	ident identState
	down  downloadState
	up    uploadState
	sx    sourceState
}

// BuildOutgoing builds the session of a connection we are dialling to
// remote. Files may be added at once; it speaks once OnOpened.
func BuildOutgoing(remote netip.AddrPort) *Session {
	s := buildSession(Config{}, remote, time.Time{})
	s.greeting = connecting
	return s
}

// OnOpened starts a session built by BuildOutgoing on the opened connection;
// the returned Output carries our Hello. cfg is taken now, not at the dial,
// so the Hello tells what we know once connected.
func (s *Session) OnOpened(cfg Config, now time.Time) Output {
	s.cfg = cfg
	s.lastActive = now
	s.greeting = awaitingHelloAnswer
	var out Output
	out.send(client.Hello(s.buildHello()))
	return out
}

// BuildIncoming starts a session on a connection remote opened to us; it
// waits for the peer's Hello.
func BuildIncoming(cfg Config, remote netip.AddrPort, now time.Time) *Session {
	return buildSession(cfg, remote, now)
}

func buildSession(cfg Config, remote netip.AddrPort, now time.Time) *Session {
	return &Session{
		cfg:        cfg,
		remote:     netip.AddrPortFrom(remote.Addr().Unmap(), remote.Port()),
		lastActive: now,
		timeout:    connectionTimeout,
		up:         uploadState{parts: map[wire.Hash]piece.Set{}},
		sx:         sourceState{asked: map[wire.Hash]bool{}},
	}
}

func (s *Session) Capabilities() Capabilities { return s.caps }

// IsUploading tells whether the peer holds an upload slot with us.
func (s *Session) IsUploading() bool { return s.up.slot != nil }

// OnPacket reacts to one packet from the peer.
func (s *Session) OnPacket(p wire.Packet, now time.Time) Output {
	s.lastActive = now
	var out Output
	if s.greeting != handshaken {
		s.onGreeting(p, &out)
		return out
	}
	switch p := p.(type) {
	case client.Hello, client.HelloAnswer:
		out.Close = closeProtocol
	case client.EmuleInfo:
		s.onEmuleInfo(p, &out)
	case client.IPv6Changed:
		s.caps.IPv6 = toPublicIPv6(p.Addr)
	case client.PublicIPRequest:
		// A peer we reach over IPv6 has no IPv4 address to be told
		// (ClientTCPSocket.cpp:1739).
		if s.remote.Addr().Is4() {
			out.send(client.PublicIPAnswer{Addr: s.remote.Addr()})
		}
	case client.SecureIdentState:
		s.onIdentState(p, &out)
	case client.PublicKey:
		s.onPublicKey(p, &out)
	case client.Signature:
		s.onSignature(p, &out)

	case client.FileNameAnswer:
		s.onFileName(p.Hash, &out)
	case client.FileStatus:
		s.onFileStatus(p, &out)
	case client.MultiPacketAnswer:
		s.onMultiPacketAnswer(p.Answers, &out)
	case client.MultiPacketAnswerExt2:
		s.onMultiPacketAnswerExt2(p, &out)
	case client.NoFile:
		s.onNoFile(p.Hash, &out)
	case client.HashSetAnswer:
		s.onHashSet(p, &out)
	case client.QueueRanking:
		s.onQueueRank(uint32(p.Rank), &out)
	case client.QueueRank:
		s.onQueueRank(p.Rank, &out)
	case client.AcceptUploadRequest:
		s.onSlotGranted(now, &out)
	case client.OutOfParts:
		s.stopSlot(&out)
	case client.SendingPart:
		s.onPart(p.Hash, int64(p.Start), p.Data, now, &out)
	case client.CompressedPart:
		s.onCompressedPart(p.Hash, int64(p.Start), p.PackedSize, p.Data, now, &out)
	case client.AICHFileHashAnswer:
		s.onRoot(p.Hash, p.Root, &out)
	case client.AICHAnswer:
		s.onRecoveryAnswer(p, &out)

	case client.FileRequest:
		s.onFileRequest(p, &out)
	case client.SetRequestFileID:
		s.onStatusRequest(p.Hash, &out)
	case client.MultiPacket:
		s.onMultiPacket(client.FileIdentifier{Hash: p.Hash}, p.Requests, false, now, &out)
	case client.MultiPacketExt:
		s.onMultiPacket(client.FileIdentifier{Hash: p.Hash, Size: p.Size}, p.Requests, false, now, &out)
	case client.MultiPacketExt2:
		s.onMultiPacket(p.File, p.Requests, true, now, &out)
	case client.HashSetRequest:
		s.onHashSetRequest(p.Hash, &out)
	case client.HashSetRequest2:
		s.onHashSetRequest2(p, &out)
	case client.StartUploadRequest:
		s.onUploadRequest(p.Hash, &out)
	case client.RequestParts:
		s.onPartsRequest(p.Hash, toBlocks(p), &out)
	case client.CancelTransfer:
		s.onUploadCancelled(&out)
	case client.AICHFileHashRequest:
		if share, ok := s.cfg.ShareByHash(p.Hash); ok {
			if answer, ok := s.onRootRequest(p.Hash, share, &out); ok {
				out.send(answer)
			}
		}
	case client.AICHRequest:
		s.onRecoveryRequest(p, &out)

	case client.RequestSources2:
		s.onSourcesRequest(p, now, &out)
	case client.AnswerSources2:
		s.onSourcesAnswer(p, &out)
	}
	return out
}

// OnSent notes that a packet was written to the peer. aMule resets the
// connection timeout on every send as well as every receive
// (ClientTCPSocket.cpp:1840-1850, 2010-2035), so a peer we upload to slowly
// is not dropped.
func (s *Session) OnSent(now time.Time) {
	s.lastActive = now
}

// SetIdleTimeout sets how long the connection may be silent before it
// counts as dead; aMule gives a Kad buddy link longer than other
// connections (ClientTCPSocket.cpp:144).
func (s *Session) SetIdleTimeout(d time.Duration) {
	s.timeout = d
}

// OnTick closes an idle connection and gives up a slot that stopped
// delivering.
func (s *Session) OnTick(now time.Time) Output {
	var out Output
	if s.greeting == connecting {
		return out
	}
	if now.Sub(s.lastActive) > s.timeout {
		out.Close = closeTimeout
		return out
	}
	if s.down.slot == slotGranted && s.hasBlocksInFlight() && now.Sub(s.down.lastData) > downloadTimeout {
		out.send(client.CancelTransfer{})
		s.stopSlot(&out)
	}
	return out
}
