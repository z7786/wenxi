package transfer

import (
	"fmt"
	"maps"
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

// Timing and limits follow eMule (Opcodes.h, Preferences.cpp, PartFile.cpp,
// DownloadClient.cpp, DeadSourceList.cpp) so Kelpie never asks more often
// than eMule does; the reask interval is aMule's, which is still well above
// politeGap.
const (
	// fileReaskTime is aMule's FILEREASKTIME (include/protocol/ed2k/
	// Constants.h:35), counted from when we last connected to the source or
	// it last told us its rank, with no further connect guard
	// (PartFile.cpp:1604-1621).
	fileReaskTime = 1300 * time.Second
	// udpReaskLead is the window before the TCP reask in which a queued
	// source is reasked with OP_REASKFILEPING instead: aMule tries it once
	// FILEREASKTIME-20000 ms have passed (PartFile.cpp:1594-1601), eMule two
	// minutes before.
	udpReaskLead = 20 * time.Second
	// callbackTimeout is CONNECTION_TIMEOUT, how long a callback may take.
	callbackTimeout = 40 * time.Second
	// deadSourceTime is how long a source we could not reach, or that did
	// not answer, waits on aMule's global dead source list, and
	// deadFileSourceTime one that does not have the file on the file's own;
	// a LowID or firewalled source, reached only by callback, waits
	// callbackDeadTime more (DeadSourceList.cpp:34-35, BLOCKTIME and
	// BLOCKTIMEFW). eMule's global list waits less: 15 and 30 minutes.
	deadSourceTime     = 30 * time.Minute
	deadFileSourceTime = 45 * time.Minute
	callbackDeadTime   = 15 * time.Minute
	// banTime is CLIENTBANTIME (Constants.h:66), how long a source that sent
	// corrupt data stays refused.
	banTime = 2 * time.Hour

	// A client counts our OP_STARTUPLOADREQ, OP_REASKFILEPING and
	// OP_AICHREQUEST against us when one comes within MIN_REQUESTTIME of the
	// one before: aMule 3.1.0 adds 3 to a score, takes 1 off for a later one
	// and bans at 10 (CheckForAggressive, UploadClient.cpp:656-683, called at
	// ClientTCPSocket.cpp:659, 1768 and ClientUDPSocket.cpp:441); eMule
	// counts only OP_STARTUPLOADREQ, per file, adds 1 and bans at 4
	// (AddRequestCount, UploadClient.cpp:664-688). Each source mirrors the
	// aMule score so that asking it again at once, as aMule does after a
	// pause, never gets us banned.
	//
	// politeGap is the longer MIN_REQUESTTIME, eMule's 10 minutes, and a
	// minute more, so that latency cannot bring a request we count as polite
	// to the client sooner than MIN_REQUESTTIME after the one before.
	politeGap    = 11 * time.Minute
	quickPenalty = 3
	// holdAggressiveness: a request that would bring the score to it waits
	// until it is polite, so the score stays at most 6. The source we know
	// nothing of starts at unknownAggressiveness, for a request the client
	// may have counted from an earlier Engine Process. Since we never count
	// less than the client does (see addRequest), aMule's score stays at
	// most 6+3, below its 10, and eMule's count, which grows by 1 where ours
	// grows by 3, at most 3, below its 4.
	holdAggressiveness    = 7
	unknownAggressiveness = 3

	exchangeReaskSlow = 40 * time.Minute // SOURCECLIENTREASKS
	exchangeReaskFast = 5 * time.Minute  // SOURCECLIENTREASKF
	commonPenalty     = 4                // MINCOMMONPENALTY
	rareFile          = 50               // RARE_FILE

	// maxSources is eMule's MaxSourcesPerFile default.
	maxSources = 400
	// noNeededPurgeTime and noNeededPurgeShare: near the source cap, one
	// source with no part we need is dropped at most every 40 s once the
	// file has 80% of maxSources (aMule PartFile.cpp:1559-1573).
	noNeededPurgeTime  = 40 * time.Second
	noNeededPurgeShare = 0.8
	// maxSourcesSoft is GetMaxSourcePerFileSoft: 9/10 of maxSources, capped
	// at MAX_SOURCES_FILE_SOFT (750). Above it no more sources are asked for.
	maxSourcesSoft = maxSources * 9 / 10

	// UDP reasks to a source stop once more than 3 were sent and over 30%
	// went unanswered (CUpDownClient::UDPReaskForDownload).
	minUDPReasks      = 3
	maxUDPFailedShare = 0.3
)

type sourceState int

const (
	// stateNew sources are ready to be asked once their reask time comes.
	stateNew sourceState = iota
	stateConnecting
	// stateAsking sources are connected and have not yet answered our file
	// request.
	stateAsking
	// stateQueued sources answered our file request, so we asked them for a
	// slot: aMule sets DS_ONQUEUE as soon as OP_STARTUPLOADREQ is sent
	// (BaseClient.cpp:1280-1290), before any queue rank arrives.
	stateQueued
	// stateReasking sources are queued and were sent OP_REASKFILEPING that
	// has not been answered yet.
	stateReasking
	stateDownloading
	// stateFailed sources wait out their deadline before they are tried
	// again.
	stateFailed
)

// Source is what a channel, or the source itself in its Hello, says about one
// source. A HighID source has an Endpoint. A LowID source has ClientID and the
// Server it is connected to. A firewalled Kad source has its Buddy and
// BuddyID. UserHash is zero when the channel does not tell it.
type Source struct {
	Endpoint netip.AddrPort
	ClientID uint32
	Server   netip.AddrPort
	Buddy    netip.AddrPort
	BuddyID  wire.Hash
	UserHash wire.Hash
	UDPPort  uint16
	// CanObfuscate: the source supports protocol obfuscation, which needs
	// its UserHash. What its Hello says replaces what a channel said, as
	// aMule takes it from the Hello (BaseClient.cpp:350, 590).
	CanObfuscate bool
	// IsDirectCallback: a firewalled source that takes callback requests
	// itself, at the UDP endpoint in Buddy, as Kad or its Hello said.
	IsDirectCallback bool
	// CanReaskUDP, CanExchange and Software are known only from the Hello.
	CanReaskUDP bool
	CanExchange bool
	Software    string
}

// Tick carries what OnTick needs to know about the engine.
type Tick struct {
	Now time.Time
	// ConnectBudget is how many connections this Transfer may open now.
	// Callbacks do not count: the peer connects to us (aMule 3.1.0 counts
	// only the sockets it opens toward MaxConperFive).
	ConnectBudget int
	// Server is the server we are connected to; invalid when none.
	Server netip.AddrPort
	// IsFirewalled is true when peers cannot connect to us (LowID).
	IsFirewalled bool
	// IsOffline: neither a server nor Kad is up.
	IsOffline bool
	// PublicIP is our address as the server or peers see it; invalid while
	// unknown. Port is our TCP listen port.
	PublicIP netip.Addr
	Port     uint16
	// LocalAddrs are the addresses of this host's network interfaces.
	LocalAddrs []netip.Addr
}

type source struct {
	key string
	Source
	// channel and rank exist only for Progress: where the source was first
	// found, and the queue rank it last told us, 0 while unknown.
	channel Channel
	rank    int

	state sourceState
	// deadline is when a callback in stateConnecting gives up, zero for a
	// Connect the engine answers itself, and when a source in stateFailed is
	// tried again.
	deadline time.Time
	// isNoNeeded: its last part status had no part we need (aMule
	// DS_NONEEDEDPARTS).
	isNoNeeded bool
	// a4afUntil: until then another Transfer asks this client for a slot,
	// and this one leaves it alone (aMule's A4AF list).
	a4afUntil time.Time
	// isDialledPlain: our last Connect went out plain because no channel
	// had told us the source's user hash and crypt support yet.
	isDialledPlain bool
	peer           uint64

	lastAsked    time.Time
	lastExchange time.Time
	// lastRequest and aggressiveness mirror what the source's client keeps
	// of our requests (see politeGap). They go with the source to the file's
	// next Run, as the client keeps them across our Runs.
	lastRequest    time.Time
	aggressiveness int

	udpReasks int
	udpFailed int

	receivedBytes int64
	// goodBytes and badBytes are what the source sent that a part or AICH
	// hash proved good or corrupt, for aMule's corruption black box: a
	// source is banned only when its share of corrupt data is too high.
	goodBytes int64
	badBytes  int64
	// download is the source's own rate, which the endgame compares to
	// find a source slow enough to hand its blocks over.
	download meter
}

func buildKey(s Source) string {
	switch {
	case s.Buddy.IsValid():
		return "kad:" + s.UserHash.String()
	case s.ClientID != 0:
		return fmt.Sprintf("%d@%s", s.ClientID, s.Server)
	default:
		return s.Endpoint.String()
	}
}

func (t *Transfer) buildTrace(now time.Time, s *source, event Event) TraceEvent {
	return TraceEvent{Time: now, Hash: t.file.Hash, Source: s.key, Event: event}
}

func matchSource(s *source, found Source) bool {
	switch {
	case found.UserHash != (wire.Hash{}) && found.UserHash == s.UserHash:
		return true
	case found.ClientID != 0:
		return found.ClientID == s.ClientID && found.Server == s.Server
	default:
		return found.Endpoint.IsValid() && found.Endpoint == s.Endpoint
	}
}

func (t *Transfer) matchingSource(found Source) *source {
	for _, s := range t.sources {
		if matchSource(s, found) {
			return s
		}
	}
	return nil
}

func (t *Transfer) isBanned(found Source, now time.Time) bool {
	return found.UserHash != (wire.Hash{}) && now.Before(t.bannedHashes[found.UserHash]) ||
		found.Endpoint.IsValid() && now.Before(t.bannedEndpoints[found.Endpoint])
}

func (t *Transfer) isUsable(found Source) bool {
	switch {
	case found.Buddy.IsValid():
		return found.UserHash != (wire.Hash{}) && wire.IsPublic(found.Buddy.Addr())
	case found.ClientID != 0:
		return wire.IsLowID(found.ClientID) && found.Server.IsValid()
	default:
		return found.Endpoint.IsValid() && found.Endpoint.Port() != 0 && wire.IsPublic(found.Endpoint.Addr()) && !t.isSelf(found.Endpoint)
	}
}

// isSelf follows aMule CPartFile::CanAddSource (PartFile.cpp:1745-1766):
// while LowID any source at our public IP is ourselves seen through our NAT;
// while HighID it is us only on our own port. A host with a public address
// on an interface, as with most IPv6, is also us there on our own port.
func (t *Transfer) isSelf(endpoint netip.AddrPort) bool {
	addr := endpoint.Addr().Unmap()
	if endpoint.Port() == t.tick.Port && slices.Contains(t.tick.LocalAddrs, addr) {
		return true
	}
	return addr == t.tick.PublicIP.Unmap() && (t.tick.IsFirewalled || endpoint.Port() == t.tick.Port)
}

// OnSourcesFound adds sources from one channel, skipping duplicates, banned
// sources and anything beyond the per-file source cap.
func (t *Transfer) OnSourcesFound(found []Source, channel Channel, now time.Time) []Action {
	if !t.isDownloading() {
		return nil
	}
	var actions []Action
	for _, f := range found {
		actions = append(actions, t.addSource(f, channel, now)...)
	}
	return actions
}

func (t *Transfer) addSource(found Source, channel Channel, now time.Time) []Action {
	// A LowID source can only be reached by a callback, which a firewalled
	// client cannot get (aMule CPartFile::CanAddSource, PartFile.cpp:1769).
	usable := t.isUsable(found)
	if channel == channelLink && found.ClientID == 0 && !found.Buddy.IsValid() {
		// Only addresses explicitly supplied by the user may target the LAN.
		usable = wire.IsDialable(found.Endpoint) && !t.isSelf(found.Endpoint)
	}
	if !usable || t.isBanned(found, now) || found.ClientID != 0 && t.tick.IsFirewalled {
		return nil
	}
	if s := t.matchingSource(found); s != nil {
		if s.UserHash == (wire.Hash{}) {
			s.UserHash = found.UserHash
		}
		if s.UDPPort == 0 {
			s.UDPPort = found.UDPPort
		}
		if found.CanObfuscate && !s.CanObfuscate && s.state == stateFailed && s.isDialledPlain {
			s.state = stateNew
		}
		s.CanObfuscate = s.CanObfuscate || found.CanObfuscate
		return nil
	}
	s := t.addNew(found, channel)
	if s == nil {
		return nil
	}
	event := t.buildTrace(now, s, EventFound)
	event.Channel = channel
	return []Action{event}
}

// addNew makes room at the cap by dropping a failed source or one we cannot
// reach; without one, the new source is refused.
func (t *Transfer) addNew(found Source, channel Channel) *source {
	if len(t.sources) >= maxSources {
		i := slices.IndexFunc(t.sources, func(s *source) bool { return !t.isValid(s) })
		if i < 0 {
			return nil
		}
		t.sources = slices.Delete(t.sources, i, i+1)
	}
	s := &source{key: buildKey(found), Source: found, channel: channel, aggressiveness: unknownAggressiveness}
	t.sources = append(t.sources, s)
	return s
}

func (t *Transfer) removeSource(s *source) {
	t.sources = slices.DeleteFunc(t.sources, func(other *source) bool { return other == s })
}

// validSourceCount counts the sources that the "enough sources" limits may
// rely on: not failed and reachable from where we are now.
func (t *Transfer) validSourceCount() int {
	count := 0
	for _, s := range t.sources {
		if t.isValid(s) {
			count++
		}
	}
	return count
}

func (t *Transfer) isConnected(s *source) bool {
	return t.peers[s.peer] == s
}

func (t *Transfer) isValid(s *source) bool {
	return s.state != stateFailed && (t.isConnected(s) || t.canReach(s))
}

// canReach mirrors requestConnect: callbacks need us reachable, and a server
// callback needs the source on our server. A LowID peer on no server, as a
// firewalled Kad client names itself 1 in its Hello, has none to call
// through.
func (t *Transfer) canReach(s *source) bool {
	switch {
	case s.Buddy.IsValid():
		return !t.tick.IsFirewalled
	case s.ClientID != 0:
		return !t.tick.IsFirewalled && s.Server.IsValid() && s.Server == t.tick.Server
	default:
		return true
	}
}

// OnConnectFailed reports that a Connect to endpoint did not succeed.
//
// A plain Connect fails against a client that requires obfuscation, and a
// source found first through a channel without user hashes (global server
// UDP) is dialled plain. When another channel has meanwhile told its user
// hash and crypt support, or tells it later, the source is dialled once
// more, obfuscated. aMule has no such retry and keeps the source dead
// (BaseClient.cpp:1335-1343); it meets this less because it starts global
// UDP only once connected to a server (DownloadQueue.cpp:883), after Kad
// has answered.
func (t *Transfer) OnConnectFailed(endpoint netip.AddrPort, reason string, now time.Time) []Action {
	for _, s := range t.sources {
		if s.state == stateConnecting && s.Endpoint == endpoint {
			event := t.setFailed(s, deadSourceTime, reason, now)
			if s.isDialledPlain && s.CanObfuscate {
				s.state = stateNew
			}
			return []Action{event}
		}
	}
	return nil
}

// setFailed puts the source on the dead list for wait. Offline a failure
// says nothing about the source, which only waits for its next reask, once
// we are back online.
func (t *Transfer) setFailed(s *source, wait time.Duration, reason string, now time.Time) TraceEvent {
	switch {
	case t.tick.IsOffline:
		s.state, s.lastAsked = stateNew, now
	case s.ClientID != 0 || s.Buddy.IsValid():
		s.state, s.deadline = stateFailed, now.Add(wait+callbackDeadTime)
	default:
		s.state, s.deadline = stateFailed, now.Add(wait)
	}
	event := t.buildTrace(now, s, EventFailed)
	event.Reason = reason
	return event
}

// OnPeerConnected attaches a connection that is about this file, whether we
// opened it, a callback made the source connect, or the peer came on its own.
// hello is what the peer said about itself; its Endpoint has the peer's TCP
// listen port. A LowID peer that takes direct callbacks is called back that
// way from now on, before its server or buddy, as aMule does for any LowID
// client (BaseClient.cpp:1718-1747).
func (t *Transfer) OnPeerConnected(peer uint64, hello Source, now time.Time) []Action {
	if !t.isDownloading() {
		return nil
	}
	found := Source{Endpoint: hello.Endpoint, UserHash: hello.UserHash, UDPPort: hello.UDPPort}
	if hello.ClientID != 0 {
		found.ClientID = hello.ClientID
		found.Server = hello.Server
	}
	if hello.IsDirectCallback {
		found.Buddy, found.IsDirectCallback = hello.Buddy, true
	}
	if t.isBanned(found, now) {
		return []Action{Close{Peer: peer, Reason: "banned", IsBanned: true}}
	}
	s := t.connectedSource(hello)
	var actions []Action
	if s == nil {
		s = t.addNew(found, channelIncoming)
		if s == nil {
			return []Action{Close{Peer: peer, Reason: "too many sources"}}
		}
		event := t.buildTrace(now, s, EventFound)
		event.Channel = channelIncoming
		actions = append(actions, event)
	}
	if t.isConnected(s) {
		return append(actions, Close{Peer: peer, Reason: "duplicate"})
	}
	t.sources = slices.DeleteFunc(t.sources, func(other *source) bool {
		return other != s && !t.isConnected(other) && hello.UserHash != (wire.Hash{}) && other.UserHash == hello.UserHash
	})

	s.Endpoint = hello.Endpoint
	s.UserHash = hello.UserHash
	s.UDPPort = hello.UDPPort
	s.CanReaskUDP = hello.CanReaskUDP
	s.CanExchange = hello.CanExchange
	s.CanObfuscate = hello.CanObfuscate
	s.Software = hello.Software
	if hello.IsDirectCallback {
		s.Buddy, s.IsDirectCallback = hello.Buddy, true
	}
	s.state = stateAsking
	s.a4afUntil = time.Time{}
	s.lastAsked = now
	s.peer = peer
	t.peers[peer] = s
	t.senders[peer] = s

	event := t.buildTrace(now, s, EventConnected)
	event.IsIPv6 = hello.Endpoint.Addr().Is6() && !hello.Endpoint.Addr().Is4In6()
	actions = append(actions, event)
	if t.isExchangeAllowed(s, now) {
		s.lastExchange = now
		t.lastExchangeAsk = now
		actions = append(actions, RequestSources{Peer: peer})
	}
	return actions
}

func (t *Transfer) connectedSource(hello Source) *source {
	for _, s := range t.sources {
		if s.state == stateConnecting && s.Endpoint.IsValid() && s.Endpoint == hello.Endpoint {
			return s
		}
	}
	for _, s := range t.sources {
		switch {
		case hello.UserHash != (wire.Hash{}) && s.UserHash == hello.UserHash,
			s.Endpoint.IsValid() && s.Endpoint == hello.Endpoint,
			s.ClientID != 0 && s.ClientID == hello.ClientID && s.Server == hello.Server:
			return s
		}
	}
	return nil
}

// isExchangeAllowed follows CUpDownClient::IsSourceRequestAllowed: rare files
// ask each source every SOURCECLIENTREASKS and the file every
// SOURCECLIENTREASKF; common files wait MINCOMMONPENALTY times longer.
func (t *Transfer) isExchangeAllowed(s *source, now time.Time) bool {
	count := t.validSourceCount()
	if !s.CanExchange || count >= maxSourcesSoft {
		return false
	}
	isSourceDue := func(wait time.Duration) bool {
		return s.lastExchange.IsZero() || now.Sub(s.lastExchange) > wait
	}
	isFileDue := func(wait time.Duration) bool {
		return t.lastExchangeAsk.IsZero() || now.Sub(t.lastExchangeAsk) > wait
	}
	return count <= rareFile/5 && isSourceDue(exchangeReaskSlow) ||
		count <= rareFile && isSourceDue(exchangeReaskSlow) && isFileDue(exchangeReaskFast) ||
		isSourceDue(exchangeReaskSlow*commonPenalty) && isFileDue(exchangeReaskFast*commonPenalty)
}

// OnQueued records the queue rank a peer gave us. A slot that ended keeps
// the reask counted from when we last asked the source, not from the end of
// the slot: aMule sets m_dwLastAskedTime only when it asks
// (DownloadClient.cpp:138-140, 1230-1235), so a source whose reask came due
// during the slot is asked again at once and queues up anew.
func (t *Transfer) OnQueued(peer uint64, rank int, now time.Time) []Action {
	s := t.peers[peer]
	if !t.isDownloading() || s == nil {
		return nil
	}
	var actions []Action
	if s.state == stateDownloading {
		t.picker.cancel(peer)
		actions = append(actions, t.sendReceived(s, now)...)
	} else {
		s.lastAsked = now
	}
	return append(actions, t.setQueued(s, rank, now))
}

func (t *Transfer) setQueued(s *source, rank int, now time.Time) TraceEvent {
	s.state, s.rank = stateQueued, rank
	event := t.buildTrace(now, s, EventQueued)
	event.Rank = rank
	return event
}

// OnReaskAnswered records a source's answer to our ReaskUDP: OP_REASKACK
// with its rank; OP_QUEUEFULL, which aMule takes as rank 0
// (ClientUDPSocket.cpp:516-525); or OP_FILENOTFOUND, after which the source
// waits on the file's dead source list (aMule UDPReaskFNF,
// DownloadClient.cpp:1237-1258).
func (t *Transfer) OnReaskAnswered(endpoint netip.AddrPort, answer wire.Packet, now time.Time) []Action {
	s := t.reaskingSource(endpoint)
	if s == nil {
		return nil
	}
	rank := 0
	switch a := answer.(type) {
	case client.ReaskAck:
		rank = int(a.Rank)
	case client.QueueFull:
	case client.FileNotFound:
		return []Action{t.setFailed(s, deadFileSourceTime, "file not found", now)}
	default:
		return nil
	}
	s.lastAsked = now
	return []Action{t.setQueued(s, rank, now)}
}

func (t *Transfer) reaskingSource(endpoint netip.AddrPort) *source {
	for _, s := range t.sources {
		if s.state == stateReasking && netip.AddrPortFrom(s.Endpoint.Addr(), s.UDPPort) == endpoint {
			return s
		}
	}
	return nil
}

// OnSlotAsked records that we sent the peer OP_STARTUPLOADREQ for the file.
func (t *Transfer) OnSlotAsked(peer uint64, now time.Time) {
	if s := t.peers[peer]; s != nil {
		s.addRequest(now, true)
	}
}

// addRequest counts a request as the source's client does. Only a slot ask
// is forgiven: eMule forgives no other request, and to aMule forgiving less
// only makes our score higher than its own. We measure from our last
// request of any kind and the client from its last counted one, never
// later, so a request quick to the client is quick to us.
func (s *source) addRequest(now time.Time, isSlotAsk bool) {
	switch {
	case s.lastRequest.IsZero():
	case now.Sub(s.lastRequest) < politeGap:
		s.aggressiveness += quickPenalty
	case isSlotAsk:
		s.aggressiveness = max(0, s.aggressiveness-1)
	}
	s.lastRequest = now
}

// isHeld: the source is due to be asked and waits only for holdUntil.
func (t *Transfer) isHeld(s *source, now time.Time) bool {
	return (s.state == stateNew || s.state == stateQueued) && !t.isConnected(s) &&
		!now.Before(s.reaskDue()) && now.Before(s.holdUntil())
}

// holdUntil is when the source may next be asked: at once, unless the
// request would bring its score to holdAggressiveness.
func (s *source) holdUntil() time.Time {
	if s.aggressiveness+quickPenalty < holdAggressiveness {
		return time.Time{}
	}
	return s.lastRequest.Add(politeGap)
}

func (t *Transfer) OnSlotGranted(peer uint64, now time.Time) []Action {
	s := t.peers[peer]
	if !t.isDownloading() || s == nil {
		return nil
	}
	s.state = stateDownloading
	return []Action{t.buildTrace(now, s, eventSlot)}
}

// OnPeerGone detaches a closed connection. A source that answered our file
// request keeps its place and is reasked a reask interval after we connected,
// even when it closed before telling its queue rank, as a full upload queue
// does, or closed during its slot; only one that never answered counts as
// failed (aMule CUpDownClient::Disconnected, BaseClient.cpp:1280-1290:
// DS_ONQUEUE is set as soon as OP_STARTUPLOADREQ is sent and is kept,
// DS_CONNECTED goes to the dead list).
func (t *Transfer) OnPeerGone(peer uint64, reason string, now time.Time) []Action {
	s := t.peers[peer]
	if s == nil {
		return nil
	}
	actions := append(t.removePeer(peer, now), t.sendReceived(s, now)...)
	switch s.state {
	case stateAsking:
		return append(actions, t.setFailed(s, deadSourceTime, reason, now))
	case stateDownloading:
		s.state = stateQueued
	}
	event := t.buildTrace(now, s, EventClosed)
	event.Reason = reason
	return append(actions, event)
}

// Stop detaches every peer when the Run ends and keeps the sources for
// Options.Previous of the file's next Run, as aMule keeps a paused file's
// sources (CPartFile::PauseFile, PartFile.cpp:2799-2846). The engine sends
// OP_CANCELTRANSFER to a source that was sending, which is asked again at
// once, as aMule does (ResetLastAskedTime, PartFile.cpp:2828-2830), unless
// that would count as aggressive (see holdUntil). Every other source keeps
// its reask time. A Connect the engine was to answer is made again; a
// callback still times out.
func (t *Transfer) Stop(now time.Time) []Action {
	var actions []Action
	for _, s := range t.sources {
		if !t.isConnected(s) {
			if s.state == stateConnecting && s.deadline.IsZero() {
				s.state = stateNew
			}
			continue
		}
		delete(t.peers, s.peer)
		actions = append(actions, t.sendReceived(s, now)...)
		switch s.state {
		case stateAsking:
			s.state = stateNew
		case stateDownloading:
			s.state = stateNew
			s.lastAsked = time.Time{}
		}
		event := t.buildTrace(now, s, EventClosed)
		event.Reason = "run ended"
		actions = append(actions, event)
	}
	return actions
}

func (t *Transfer) sendReceived(s *source, now time.Time) []Action {
	if s.receivedBytes == 0 {
		return nil
	}
	event := t.buildTrace(now, s, EventReceived)
	event.Bytes = s.receivedBytes
	s.receivedBytes = 0
	return []Action{event}
}

// removeCorrupt closes and forgets a peer that sent corrupt data, and refuses its user
// hash and endpoint from now on.
func (t *Transfer) removeCorrupt(peer uint64, now time.Time) []Action {
	s := t.senders[peer]
	if s == nil {
		return nil
	}
	if s.UserHash != (wire.Hash{}) {
		t.bannedHashes[s.UserHash] = now.Add(banTime)
	}
	if s.Endpoint.IsValid() {
		t.bannedEndpoints[s.Endpoint] = now.Add(banTime)
	}
	t.removeSource(s)
	event := t.buildTrace(now, s, EventClosed)
	event.Reason = "banned"
	actions := []Action{event}
	if t.peers[peer] == s {
		actions = append(actions, Close{Peer: peer, Reason: "corrupt data", IsBanned: true})
		actions = append(actions, t.removePeer(peer, now)...)
	}
	return actions
}

// removePeer detaches a connection from its source and hands what was asked
// of it to other peers.
func (t *Transfer) removePeer(peer uint64, now time.Time) []Action {
	delete(t.peers, peer)
	t.picker.onPeerGone(peer)
	if peer == t.hashSetPeer {
		t.hashSetPeer = 0
	}
	return t.OnRecoveryFailed(peer, now)
}

// OnTick runs the timers: source reasks and connections within the budget,
// callback timeouts and the hash set request.
func (t *Transfer) OnTick(tick Tick) []Action {
	if !t.isRunning() || t.mode == ModeSeed {
		return nil
	}
	t.tick = tick
	t.removeExpired(tick.Now)
	if tick.IsFirewalled {
		t.sources = slices.DeleteFunc(t.sources, func(s *source) bool { return s.ClientID != 0 && !t.isConnected(s) })
	}
	t.removeNoNeeded(tick.Now)
	var actions []Action
	budget := tick.ConnectBudget
	for _, s := range slices.Clone(t.sources) {
		actions = append(actions, t.runSource(s, &budget, tick.Now)...)
	}
	return append(actions, t.requestHashSet()...)
}

// SetA4AF leaves a source to another Transfer until the given time: that
// Transfer is asking the client for a slot, and asking it for this file as
// well would count as aggressive on the client (aMule's A4AF list,
// DownloadQueue.cpp:623-717). Meanwhile the source is neither connected to
// nor reasked. found names the source by user hash or endpoint, and gives it
// the user hash it lacked.
func (t *Transfer) SetA4AF(found Source, until time.Time) {
	for _, s := range t.sources {
		if !matchSource(s, found) {
			continue
		}
		if s.UserHash == (wire.Hash{}) {
			s.UserHash = found.UserHash
		}
		s.a4afUntil = until
		if s.state == stateConnecting {
			s.state = stateNew
		}
	}
}

// OnNoNeededParts records that a connected source has no part we still
// need, or gave a slot with nothing left to request, and reports whether it
// now counts as such. Near completion a source that has a part we need only
// found every block of it asked of other peers, so it stays queued (aMule
// 3.1.0 "requeue instead of self-banishing at endgame",
// DownloadClient.cpp:647-652).
func (t *Transfer) OnNoNeededParts(peer uint64) bool {
	s := t.peers[peer]
	if !t.isDownloading() || s == nil || t.isNearCompletion() && t.picker.hasNeededPart(peer) {
		return false
	}
	s.isNoNeeded = true
	return true
}

func (t *Transfer) removeNoNeeded(now time.Time) {
	if float64(len(t.sources)) < maxSources*noNeededPurgeShare || now.Sub(t.lastPurge) <= noNeededPurgeTime {
		return
	}
	i := slices.IndexFunc(t.sources, func(s *source) bool { return s.isNoNeeded && !t.isConnected(s) && !now.Before(s.a4afUntil) })
	if i >= 0 {
		t.sources = slices.Delete(t.sources, i, i+1)
		t.lastPurge = now
	}
}

func (t *Transfer) runSource(s *source, budget *int, now time.Time) []Action {
	switch s.state {
	case stateFailed:
		if now.Before(s.deadline) {
			return nil
		}
		s.state = stateNew
		s.lastAsked = time.Time{}
	case stateConnecting:
		if !s.deadline.IsZero() && !now.Before(s.deadline) {
			return []Action{t.setFailed(s, deadSourceTime, "callback timeout", now)}
		}
		return nil
	case stateAsking, stateDownloading:
		return nil
	}
	if t.isConnected(s) || now.Before(s.a4afUntil) {
		return nil
	}
	// aMule asks sources only while connected to a server or Kad
	// (PartFile.cpp:1739-1757): offline every ask fails and would mark the
	// source dead. A source never asked, as a link's at startup, is tried.
	if t.tick.IsOffline && !s.lastAsked.IsZero() {
		return nil
	}

	untilReask := max(0, s.reaskDue().Sub(now))
	canAsk := !now.Before(s.holdUntil())
	// A source due a Source Exchange is reasked over TCP, which can carry
	// the exchange (aMule UDPReaskForDownload, DownloadClient.cpp:1275-1279).
	if s.state == stateQueued && !s.isNoNeeded && untilReask < udpReaskLead && untilReask > 0 && canAsk && t.canReaskUDP(s) && !t.isExchangeAllowed(s, now) {
		s.state = stateReasking
		s.udpReasks++
		s.addRequest(now, false)
		return []Action{ReaskUDP{Endpoint: netip.AddrPortFrom(s.Endpoint.Addr(), s.UDPPort), UserHash: s.UserHash, CanObfuscate: s.CanObfuscate}}
	}
	if untilReask > 0 || !canAsk {
		return nil
	}
	if s.state == stateReasking {
		s.state = stateQueued
		s.udpFailed++
	}
	return t.requestConnect(s, budget, now)
}

// reaskDue is when the source's reask comes; zero for one never asked.
// aMule doubles the reask of a source with nothing we need and never
// UDP-reasks it (PartFile.cpp:1574-1580).
func (s *source) reaskDue() time.Time {
	if s.lastAsked.IsZero() {
		return time.Time{}
	}
	reaskTime := fileReaskTime
	if s.isNoNeeded {
		reaskTime *= 2
	}
	return s.lastAsked.Add(reaskTime)
}

func (t *Transfer) canReaskUDP(s *source) bool {
	isReliable := s.udpReasks <= minUDPReasks || float64(s.udpFailed)/float64(s.udpReasks) <= maxUDPFailedShare
	return s.CanReaskUDP && s.UDPPort != 0 && s.ClientID == 0 && !s.Buddy.IsValid() &&
		!t.tick.IsFirewalled && isReliable
}

func (t *Transfer) requestConnect(s *source, budget *int, now time.Time) []Action {
	if !t.canReach(s) {
		return nil
	}
	var action Action
	switch {
	case s.Buddy.IsValid():
		action = RequestKadCallback{Buddy: s.Buddy, BuddyID: s.BuddyID, IsDirect: s.IsDirectCallback, UserHash: s.UserHash, CanObfuscate: s.CanObfuscate}
	case s.ClientID != 0:
		action = RequestServerCallback{ClientID: s.ClientID}
	default:
		action = Connect{Endpoint: s.Endpoint, UserHash: s.UserHash, CanObfuscate: s.CanObfuscate}
	}
	_, isConnect := action.(Connect)
	if isConnect {
		if *budget <= 0 {
			return nil
		}
		*budget--
	}
	s.state = stateConnecting
	s.deadline = time.Time{}
	s.isDialledPlain = isConnect && !s.CanObfuscate
	if !isConnect {
		s.deadline = now.Add(callbackTimeout)
	}
	return []Action{action}
}

// MatchSource tells whether the transfer keeps found as a source; found
// names it as for OnSourcesFound: by user hash, else by LowID client id and
// server, else by endpoint.
func (t *Transfer) MatchSource(found Source) bool {
	return t.matchingSource(found) != nil
}

// removeExpired forgets bans that ended, and the senders of connections
// that are gone and named by no block still waiting for its part hash: only
// those can still be banned for corrupt data.
func (t *Transfer) removeExpired(now time.Time) {
	maps.DeleteFunc(t.bannedHashes, func(_ wire.Hash, until time.Time) bool { return !now.Before(until) })
	maps.DeleteFunc(t.bannedEndpoints, func(_ netip.AddrPort, until time.Time) bool { return !now.Before(until) })
	senders := t.picker.senders()
	maps.DeleteFunc(t.senders, func(peer uint64, _ *source) bool {
		return t.peers[peer] == nil && !slices.Contains(senders, peer)
	})
}
