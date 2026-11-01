package server

import (
	"cmp"
	"maps"
	"math/rand/v2"
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	serverwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/server"
)

// eMule's timing and limits; names are eMule's (Opcodes.h unless noted).
const (
	connectTimeout = 25 * time.Second // CONSERVTIMEOUT, covers connect and login
	passRetryTime  = 30 * time.Second // CS_RETRYCONNECTTIME (sockets.h)
	// maxAttempts follows aMule's TryAnotherConnectionrequest
	// (ServerConnect.cpp): two servers at once unless SafeServerConnect,
	// which is off by default; the first to log in wins.
	maxAttempts = 2

	sourceReaskTime     = 15 * time.Minute            // SERVERREASKTIME
	sourceFilesPerFrame = 15                          // iMaxFilesPerTcpFrame (DownloadQueue.cpp)
	sourceFrameTime     = 15 * (16 + 4) * time.Second // m_dwNextTCPSrcReq (DownloadQueue.cpp)
	offerTime           = time.Minute                 // ED2KREPUBLISHTIME
	maxOfferFiles       = 200                         // SendListToServer limit (SharedFileList.cpp)
	dnsSolveTime        = 30 * time.Minute            // DNS_SOLVE_TIME (aMule AsyncDNS.h)
	largeFileSize       = 4290048000                  // OLD_MAX_EMULE_FILE_SIZE
	edonkeyVersion      = 0x3C                        // EDONKEYVERSION
	// CapSupportCrypt makes the server answer with OP_FOUNDSOURCES_OBFU,
	// which carries the user hash an obfuscated connection needs.
	loginFlags = serverwire.CapZlib | serverwire.CapNewTags | serverwire.CapUnicode | serverwire.CapLargeFiles |
		serverwire.CapSupportCrypt | serverwire.CapRequestCrypt

	// keepAliveTime stands in for eMule's ServerKeepAliveTimeout, which is
	// off by default; an idle seeding Engine Process would otherwise lose
	// the connection to NAT timeouts. 20 minutes is far below eMule's own
	// source-request traffic on the same connection.
	keepAliveTime = 20 * time.Minute

	// A file with this many sources is no longer searched over TCP, or
	// over UDP: GetMaxSourcePerFileSoft and GetMaxSourcePerFileUDP of the
	// transfer's 400 MaxSourcesPerFile, capped at MAX_SOURCES_FILE_SOFT and
	// MAX_SOURCES_FILE_UDP (aMule PartFile.cpp:1683, 4557-4573,
	// Constants.h:50-51; eMule DownloadQueue.cpp:927 for UDP).
	maxSourcesSoft = 360
	maxSourcesUDP  = 50
)

// Config is what the login needs about us.
type Config struct {
	UserHash wire.Hash
	Port     uint16
	// Version is the Engine Process version, such as "v0.1.0".
	Version string
	// Random picks the challenges of obfuscated status pings, which key
	// the answers.
	Random *rand.Rand
}

// Wanted is one file the engine shares or downloads, passed on every tick.
// Incomplete files are searched for sources until they have enough;
// shared files are offered to the connected server.
type Wanted struct {
	File       wire.Hash
	Size       uint64
	Name       string
	IsComplete bool
	IsShared   bool
	// Sources is how many usable sources the file has.
	Sources int
}

// Source is one peer a server named for a file. A LowID source has no
// Endpoint and is reachable only by RequestCallback through Server.
type Source struct {
	Endpoint netip.AddrPort
	ClientID uint32
	IsLowID  bool
	Server   netip.AddrPort
	UserHash wire.Hash
	// CanObfuscate: the source supports protocol obfuscation; obfuscation
	// aware servers tell it along with the user hash it needs.
	CanObfuscate bool
}

// Action is something the engine must do, or learn, in slice order. A
// server connection is named by the server's endpoint, even when dialled
// on its obfuscation port; reports about a closed one are ignored.
type Action interface{ isAction() }

// Close closes the connection to Server.
type Close struct{ Server netip.AddrPort }

// Dial opens a connection to Server. A non-zero ObfuscationPort means
// dialling that port and obfuscating the connection.
type Dial struct {
	Server          netip.AddrPort
	ObfuscationPort uint16
}

// Send sends Packet on the connection to To.
type Send struct {
	To     netip.AddrPort
	Packet wire.Packet
}

// Datagram is one UDP packet for a server's UDP port. A non-zero Key
// means obfuscating it with that server UDP key; To is then the server's
// UDP obfuscation port.
type Datagram struct {
	To     netip.AddrPort
	Packet wire.Packet
	Key    uint32
}

// Callback is a peer that asked, through the server, for us to connect.
// Obfuscation-aware servers pass on its crypt options and user hash, as
// aMule's OP_CALLBACKREQUESTED handling (ServerSocket.cpp) uses them.
type Callback struct {
	Endpoint     netip.AddrPort
	UserHash     wire.Hash
	CanObfuscate bool
}

// Resolve looks Host up; the answer goes to OnResolved.
type Resolve struct{ Host string }

// SourcesFound comes from the connected server, or from another server
// over UDP when IsGlobal.
type SourcesFound struct {
	File     wire.Hash
	Sources  []Source
	IsGlobal bool
}

// IDChanged reports the id the connected server gave us and the address
// it sees us at, invalid when it did not say; with a LowID that address
// is the only one the server tells.
type IDChanged struct {
	ClientID   uint32
	ReportedIP netip.Addr
}

type MessageReceived struct{ Text string }

func (Close) isAction()           {}
func (Dial) isAction()            {}
func (Send) isAction()            {}
func (Datagram) isAction()        {}
func (Callback) isAction()        {}
func (Resolve) isAction()         {}
func (SourcesFound) isAction()    {}
func (IDChanged) isAction()       {}
func (MessageReceived) isAction() {}

// listed is an Entry with what this process learned about it.
type listed struct {
	Entry
	// isDead marks a server that left a status ping unanswered until its
	// next turn; it is not pinged again. It is still asked for sources, as
	// aMule does: some servers answer source requests but not pings.
	isDead    bool
	challenge uint32
	// searchedAt is when the server was last asked for sources over UDP.
	searchedAt time.Time
	// tcpFlags are from the server's last OP_IDCHANGE.
	tcpFlags uint32
	// resolvedAt is when the answer for Host came; isResolving while it
	// is awaited.
	resolvedAt  time.Time
	isResolving bool
	// isCryptPinging: the status ping awaiting its answer is obfuscated.
	isCryptPinging bool
}

// isResolved: a server listed by host name has an address.
func (l *listed) isResolved() bool { return l.Endpoint.Addr().IsValid() }

// canObfuscateTCP is aMule's SupportsObfuscationTCP (Server.h:146).
func (l *listed) canObfuscateTCP() bool {
	return l.TCPObfuscationPort != 0 && (l.UDPFlags&serverwire.UDPFlagTCPObfuscation != 0 || l.tcpFlags&serverwire.FlagTCPObfuscation != 0)
}

// attempt is a server connection that has not logged in yet.
type attempt struct {
	server *listed
	since  time.Time
	// isConnected: the dial succeeded. A dial left unanswered counts
	// against the server, a login left unanswered does not
	// (CheckForTimeout, aMule ServerConnect.cpp:486-514).
	isConnected bool
}

// Server owns the server list, the connection attempts and the one
// logged-in server connection.
type Server struct {
	config  Config
	servers []*listed
	wanted  []Wanted

	attempts []attempt
	// current is the server we are logged in to.
	current *listed
	// tried holds the servers this round dialled or lost. The plain pass
	// dials again those the obfuscated pass dialled, marked true; a lost
	// server waits for the next round, so one that drops us at once is not
	// redialled in a loop.
	tried   map[*listed]bool
	retryAt time.Time
	// isPlainPass is aMule's !m_bTryObfuscated: a pass first tries only
	// servers that obfuscate, then all of them plain.
	isPlainPass bool
	clientID    uint32
	lastSent    time.Time
	publicIP    netip.Addr

	askedAt         map[wire.Hash]time.Time
	nextSourceFrame time.Time
	offered         map[wire.Hash]bool
	nextOffer       time.Time

	udp udpSearch
}

// BuildServer takes the entries of every server list; a server listed twice,
// by endpoint or by host name and port, keeps its first entry.
func BuildServer(config Config, entries []Entry) *Server {
	s := &Server{
		config:  config,
		tried:   map[*listed]bool{},
		askedAt: map[wire.Hash]time.Time{},
		offered: map[wire.Hash]bool{},
	}
	type key struct {
		host     string
		endpoint netip.AddrPort
	}
	seen := map[key]bool{}
	for _, e := range entries {
		k := key{e.Host, e.Endpoint}
		if seen[k] {
			continue
		}
		seen[k] = true
		s.servers = append(s.servers, &listed{Entry: e})
	}
	return s
}

// Entries is every listed server with what this process learned about it.
func (s *Server) Entries() []Entry {
	entries := make([]Entry, 0, len(s.servers))
	for _, l := range s.servers {
		entries = append(entries, l.Entry)
	}
	return entries
}

// Login is the server we are logged in to and the client id it gave us;
// invalid and 0 while not logged in.
func (s *Server) Login() (netip.AddrPort, uint32) {
	if s.current == nil {
		return netip.AddrPort{}, 0
	}
	return s.current.Endpoint, s.clientID
}

// OnTick takes the files the engine shares or downloads and our public
// IPv4 address, invalid while unknown; server UDP keys belong to it.
func (s *Server) OnTick(now time.Time, wanted []Wanted, publicIP netip.Addr) []Action {
	s.wanted = wanted
	s.publicIP = publicIP
	// A file wanted again, as a download stopped and run again, is asked for
	// in the next frame, as eMule and aMule ask for a resumed file
	// (CPartFile::ResumeFile; aMule PartFile.cpp:2869, eMule
	// PartFile.cpp:3923).
	maps.DeleteFunc(s.askedAt, func(file wire.Hash, _ time.Time) bool {
		return !slices.ContainsFunc(wanted, func(w Wanted) bool { return w.File == file })
	})
	var out []Action
	for _, a := range slices.Clone(s.attempts) {
		if now.Sub(a.since) > connectTimeout {
			out = append(out, Close{a.server.Endpoint})
			s.removeAttempt(a.server.Endpoint, !a.isConnected)
		}
	}
	s.runResolve(now, &out)
	s.runConnect(now, &out)
	if s.current != nil {
		s.runSession(now, &out)
		s.runStats(now, &out)
		s.runSearch(now, &out)
	}
	return out
}

// OnConnected starts the login on a dialled connection. A server that
// accepts the connection is alive, so its failures are forgiven, as in
// aMule's ConnectionEstablished (ServerConnect.cpp:247-251).
func (s *Server) OnConnected(server netip.AddrPort) []Action {
	i := s.attemptIndex(server)
	if i < 0 {
		return nil
	}
	s.attempts[i].isConnected = true
	s.attempts[i].server.Failures = 0
	login := serverwire.Login{
		UserHash:     s.config.UserHash,
		Port:         s.config.Port,
		Name:         "Kelpie",
		Version:      edonkeyVersion,
		Flags:        loginFlags,
		EmuleVersion: wire.ToEmuleVersion(s.config.Version),
	}
	return []Action{Send{server, login}}
}

// OnDisconnected handles the end of a server connection at any stage, a
// failed dial included; either way the next server is tried, as eMule's
// reconnect does. Only a dial the server refused or left unanswered,
// isRefused, counts against it: aMule 3.1.0 counts only CS_SERVERDEAD
// (ServerSocket.cpp:99-139), so that a fault of our own link does not mark
// every server at once.
func (s *Server) OnDisconnected(server netip.AddrPort, isRefused bool, now time.Time) []Action {
	switch {
	case s.current != nil && s.current.Endpoint == server:
		s.tried[s.current] = false
		s.current = nil
	case s.attemptIndex(server) >= 0:
		s.removeAttempt(server, isRefused)
	default:
		return nil
	}
	var out []Action
	s.runConnect(now, &out)
	return out
}

// OnResolved takes the address host resolved to; an invalid addr means
// the lookup failed, and the old address, if any, stays. A server in use
// keeps its address until the next lookup.
func (s *Server) OnResolved(host string, addr netip.Addr, now time.Time) []Action {
	for _, l := range s.servers {
		if l.Host != host || !l.isResolving {
			continue
		}
		l.isResolving = false
		l.resolvedAt = now
		endpoint := netip.AddrPortFrom(addr, l.Endpoint.Port())
		isInUse := l == s.current || slices.ContainsFunc(s.attempts, func(a attempt) bool { return a.server == l })
		if wire.IsDialable(endpoint) && !isInUse && s.serverByEndpoint(endpoint) == nil {
			l.Endpoint = endpoint
		}
	}
	var out []Action
	s.runConnect(now, &out)
	return out
}

// runResolve looks host names up again every DNS_SOLVE_TIME, as aMule does
// before UDP packets (ServerUDPSocket.cpp:420-450); aMule also looks one up
// before each connection, which Kelpie folds into the same cycle: a server
// is not connected while its lookup is out.
func (s *Server) runResolve(now time.Time, out *[]Action) {
	for _, l := range s.servers {
		isFresh := !l.resolvedAt.IsZero() && now.Sub(l.resolvedAt) < dnsSolveTime
		if l.Host == "" || l.isResolving || isFresh || l == s.current {
			continue
		}
		l.isResolving = true
		if !slices.Contains(*out, Action(Resolve{l.Host})) {
			*out = append(*out, Resolve{l.Host})
		}
	}
}

func (s *Server) serverByEndpoint(endpoint netip.AddrPort) *listed {
	for _, l := range s.servers {
		if l.Endpoint == endpoint {
			return l
		}
	}
	return nil
}

// OnPacket takes a packet from a server: over TCP from the server at from,
// logged in or still logging in, or over UDP from any listed server's UDP
// endpoint.
func (s *Server) OnPacket(from netip.AddrPort, p wire.Packet, now time.Time) []Action {
	switch p.(type) {
	case serverwire.GlobServStatRes, serverwire.GlobFoundSources:
		return s.onDatagram(from, p, now)
	}
	var out []Action
	sender := s.current
	if i := s.attemptIndex(from); i >= 0 {
		sender = s.attempts[i].server
	}
	if sender == nil || sender.Endpoint != from {
		return out
	}
	switch p := p.(type) {
	case serverwire.IDChange:
		s.onIDChange(sender, p, now, &out)
	case serverwire.ServerMessage:
		out = append(out, MessageReceived{Text: p.Text})
	case serverwire.ServerStatus:
		sender.Users, sender.Files = p.Users, p.Files
	}
	if sender != s.current {
		return out
	}
	switch p := p.(type) {
	case serverwire.FoundSources:
		s.addSources(p.Hash, p.Sources, sender.Endpoint, false, &out)
	case serverwire.CallbackRequested:
		if p.Addr.IsValid() && p.Addr.Port() != 0 {
			out = append(out, Callback{
				Endpoint:     p.Addr,
				UserHash:     p.UserHash,
				CanObfuscate: wire.CanObfuscate(p.CryptOptions, p.UserHash),
			})
		}
	case serverwire.CallbackRequestedIPv6:
		if p.Addr.IsValid() && p.Addr.Port() != 0 {
			out = append(out, Callback{Endpoint: p.Addr})
		}
	}
	return out
}

// RequestCallback asks the connected server to have the LowID source
// clientID, which that server named, connect to us. It is possible only
// while we are HighID.
func (s *Server) RequestCallback(clientID uint32, now time.Time) []Action {
	if s.current == nil || wire.IsLowID(s.clientID) {
		return nil
	}
	s.lastSent = now
	return []Action{Send{s.current.Endpoint, serverwire.CallbackRequest{ClientID: clientID}}}
}

// onIDChange logs in to the first attempt that gets an id and closes the
// other one, which aMule's StopConnectionTry does without counting a
// failure.
func (s *Server) onIDChange(sender *listed, p serverwire.IDChange, now time.Time, out *[]Action) {
	if p.ClientID == 0 {
		return
	}
	// aMule keeps both for the next connection (ServerSocket.cpp:262, 289-296).
	sender.tcpFlags = p.Flags
	if p.ObfuscationPort != 0 {
		sender.TCPObfuscationPort = uint16(p.ObfuscationPort)
	}
	if sender != s.current {
		for _, a := range s.attempts {
			if a.server != sender {
				*out = append(*out, Close{a.server.Endpoint})
			}
		}
		s.attempts = nil
		s.current = sender
		s.current.Failures = 0
		s.lastSent = now
		// The next reconnect starts over with the obfuscated pass, as
		// aMule's ConnectToAnyServer does (ServerConnect.cpp:144).
		s.isPlainPass = false
		clear(s.tried)
		clear(s.offered)
		s.nextSourceFrame = now
		s.nextOffer = now
	}
	s.clientID = p.ClientID
	*out = append(*out, IDChanged{ClientID: p.ClientID, ReportedIP: p.ReportedIP})
	s.runSession(now, out)
}

// addSources reports what server found for a wanted file. A LowID source
// is reachable only by a callback through the server that named it, so it
// is kept only from the connected server, and only while we are HighID.
func (s *Server) addSources(file wire.Hash, found []serverwire.Source, server netip.AddrPort, isGlobal bool, out *[]Action) {
	if !s.isWanted(file) {
		return
	}
	canCallback := !isGlobal && !wire.IsLowID(s.clientID)
	var sources []Source
	for _, f := range found {
		src, ok := s.toSource(f, server)
		if ok && (!src.IsLowID || canCallback) {
			sources = append(sources, src)
		}
	}
	if len(sources) > 0 {
		*out = append(*out, SourcesFound{File: file, Sources: sources, IsGlobal: isGlobal})
	}
}

func (s *Server) toSource(f serverwire.Source, server netip.AddrPort) (Source, bool) {
	src := Source{
		ClientID:     f.ClientID,
		Server:       server,
		UserHash:     f.UserHash,
		CanObfuscate: wire.CanObfuscate(f.CryptOptions, f.UserHash),
	}
	switch {
	case f.Port == 0 || f.ClientID == 0:
		return src, false
	case f.ClientID == wire.IPv6Sentinel:
		src.Endpoint = netip.AddrPortFrom(f.IPv6, f.Port)
		return src, f.IPv6.IsValid()
	case wire.IsLowID(f.ClientID):
		src.IsLowID = true
		return src, true
	case f.ClientID == s.clientID && f.Port == s.config.Port:
		return src, false
	}
	src.Endpoint = netip.AddrPortFrom(wire.ToAddr(f.ClientID), f.Port)
	return src, true
}

func (s *Server) isWanted(file wire.Hash) bool {
	return slices.ContainsFunc(s.wanted, func(w Wanted) bool { return w.File == file && !w.IsComplete })
}

func (s *Server) attemptIndex(server netip.AddrPort) int {
	return slices.IndexFunc(s.attempts, func(a attempt) bool { return a.server.Endpoint == server })
}

func (s *Server) removeAttempt(server netip.AddrPort, isFailed bool) {
	i := s.attemptIndex(server)
	if isFailed {
		s.attempts[i].server.Failures++
	}
	s.attempts = slices.Delete(s.attempts, i, i+1)
}

// runConnect keeps maxAttempts servers of the current pass in flight. A
// pass tries every server once, best first. As in aMule
// (ServerConnect.cpp:54-88), the first pass tries only servers that
// obfuscate, on their obfuscation port when they have one, and "another
// pass without obfuscation" follows at once. When the plain pass runs out
// and no attempt is left, eMule waits CS_RETRYCONNECTTIME so a short list
// is not hammered.
func (s *Server) runConnect(now time.Time, out *[]Action) {
	if s.current != nil || now.Before(s.retryAt) {
		return
	}
	for len(s.attempts) < maxAttempts {
		next := s.nextServer()
		switch {
		case next == nil && len(s.attempts) > 0:
			return
		case next == nil && !s.isPlainPass:
			s.isPlainPass = true
			continue
		case next == nil:
			if len(s.tried) > 0 {
				s.isPlainPass = false
				clear(s.tried)
				s.retryAt = now.Add(passRetryTime)
			}
			return
		}
		s.tried[next] = !s.isPlainPass
		s.attempts = append(s.attempts, attempt{server: next, since: now})
		dial := Dial{Server: next.Endpoint}
		if !s.isPlainPass && next.canObfuscateTCP() {
			dial.ObfuscationPort = next.TCPObfuscationPort
		}
		*out = append(*out, dial)
	}
}

// nextServer prefers high preference, then fewer failures, then more users
// and files: a bigger server knows more sources. Failures only order the
// list: a server skipped for them could never be forgiven, and aMule's
// GetNextServer skips none for them either. An obfuscated pass skips
// servers that support neither TCP nor UDP obfuscation, as GetNextServer
// does (ServerList.cpp:569-585).
func (s *Server) nextServer() *listed {
	var best *listed
	for _, l := range s.servers {
		canObfuscate := l.canObfuscateTCP() || l.UDPFlags&serverwire.UDPFlagUDPObfuscation != 0
		wasObfuscated, isTried := s.tried[l]
		isDue := !isTried || s.isPlainPass && wasObfuscated
		if !isDue || !l.isResolved() || l.isResolving || (!s.isPlainPass && !canObfuscate) {
			continue
		}
		if best == nil || isBetter(l, best) {
			best = l
		}
	}
	return best
}

func isBetter(a, b *listed) bool {
	rank := func(p Preference) int {
		switch p {
		case PreferenceHigh:
			return 0
		case PreferenceLow:
			return 2
		}
		return 1
	}
	return cmp.Or(
		cmp.Compare(rank(a.Preference), rank(b.Preference)),
		cmp.Compare(a.Failures, b.Failures),
		cmp.Compare(b.Users, a.Users),
		cmp.Compare(b.Files, a.Files),
	) < 0
}

func (s *Server) runSession(now time.Time, out *[]Action) {
	n := len(*out)
	s.runSourceRequests(now, out)
	s.runOffer(now, out)
	if len(*out) == n && now.Sub(s.lastSent) >= keepAliveTime {
		// eMule's keep-alive is an empty OP_OFFERFILES.
		s.send(serverwire.OfferFiles{}, out)
	}
	if len(*out) > n {
		s.lastSent = now
	}
}

func (s *Server) send(p wire.Packet, out *[]Action) {
	*out = append(*out, Send{s.current.Endpoint, p})
}

// runSourceRequests sends one frame of up to 15 OP_GETSOURCES, longest
// waiting file first, and no file more often than SERVERREASKTIME while it
// stays wanted. The per-file times survive reconnects, as in eMule.
func (s *Server) runSourceRequests(now time.Time, out *[]Action) {
	if now.Before(s.nextSourceFrame) {
		return
	}
	var due []Wanted
	for _, w := range s.wanted {
		at, isAsked := s.askedAt[w.File]
		if w.IsComplete || w.Sources >= maxSourcesSoft || (isAsked && now.Sub(at) < sourceReaskTime) || !s.canTCP(w.Size) {
			continue
		}
		due = append(due, w)
	}
	if len(due) == 0 {
		return
	}
	slices.SortStableFunc(due, func(a, b Wanted) int { return s.askedAt[a.File].Compare(s.askedAt[b.File]) })
	for _, w := range due[:min(len(due), sourceFilesPerFrame)] {
		isObfu := s.current.tcpFlags&serverwire.FlagTCPObfuscation != 0
		s.send(serverwire.GetSources{Hash: w.File, Size: w.Size, IsObfu: isObfu}, out)
		s.askedAt[w.File] = now
	}
	s.nextSourceFrame = now.Add(sourceFrameTime)
}

// runOffer publishes shared files the server has not seen in this
// connection, at most once per ED2KREPUBLISHTIME and capped like eMule's
// SendListToServer. A file offered while partial is offered again once
// complete.
func (s *Server) runOffer(now time.Time, out *[]Action) {
	if now.Before(s.nextOffer) {
		return
	}
	limit := maxOfferFiles
	if soft := int(s.current.SoftFiles); soft > 0 && soft < limit {
		limit = soft
	}
	var files []serverwire.OfferedFile
	for _, w := range s.wanted {
		if len(files) == limit {
			break
		}
		wasComplete, isOffered := s.offered[w.File]
		if !w.IsShared || (isOffered && wasComplete == w.IsComplete) || !s.canTCP(w.Size) {
			continue
		}
		files = append(files, s.toOffered(w))
		s.offered[w.File] = w.IsComplete
	}
	if len(files) == 0 {
		return
	}
	s.send(serverwire.OfferFiles{Files: files}, out)
	s.nextOffer = now.Add(offerTime)
}

func (s *Server) toOffered(w Wanted) serverwire.OfferedFile {
	f := serverwire.OfferedFile{Hash: w.File}
	switch {
	case s.current.tcpFlags&serverwire.FlagCompression != 0 && w.IsComplete:
		f.ClientID, f.Port = serverwire.CompleteID, serverwire.CompletePort
	case s.current.tcpFlags&serverwire.FlagCompression != 0:
		f.ClientID, f.Port = serverwire.IncompleteID, serverwire.IncompletePort
	case !wire.IsLowID(s.clientID):
		f.ClientID, f.Port = s.clientID, s.config.Port
	}
	f.Tags = []wire.Tag{
		{Type: wire.TagString, ID: serverwire.FileName, String: w.Name},
		{Type: wire.TagUint32, ID: serverwire.FileSize, Uint: w.Size & 0xFFFFFFFF},
	}
	if w.Size > 0xFFFFFFFF {
		f.Tags = append(f.Tags, wire.Tag{Type: wire.TagUint32, ID: serverwire.FileSizeHi, Uint: w.Size >> 32})
	}
	return f
}

func (s *Server) canTCP(size uint64) bool {
	return size <= largeFileSize || s.current.tcpFlags&serverwire.FlagLargeFiles != 0
}
