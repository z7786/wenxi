package kad

import (
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
)

// aMule Kademlia.cpp and kademlia/Defines.h.
const (
	firstBuddySearch  = 5 * time.Minute   // m_nextFindBuddy at start
	buddySearchGap    = 20 * time.Minute  // ...and after each search
	buddyRecheckDelay = 5 * time.Minute   // RecheckFirewalled: at least 5 min after a firewall check
	buddyLifetime     = 100 * time.Second // SEARCHFINDBUDDY_LIFETIME
	buddyTotal        = 10                // SEARCHFINDBUDDY_TOTAL
	// connectOptions are ours as FINDBUDDY_RES carries them
	// (CPrefs::GetMyConnectOptions(true, false)): obfuscation supported and
	// requested.
	connectOptions byte = 0x03
)

// Buddy is the engine's buddy link as Kad needs to know it: aMule's
// CClientList buddy status (ClientList.cpp:560-720).
type Buddy struct {
	IsConnecting bool
	// IsConnected: a link is up, to our buddy or to a client we serve.
	IsConnected bool
	// Addr is our buddy's IP and UDP port while it serves us; others reach
	// us through it.
	Addr netip.AddrPort
}

// BuddyFound asks the engine to connect to an open node that agreed to be
// our buddy (KADEMLIA_FINDBUDDY_RES).
type BuddyFound struct {
	Addr         netip.AddrPort
	UserHash     wire.Hash
	CryptOptions byte
}

// BuddyRequested tells the engine that the firewalled client at Addr will
// connect to us as its buddy; BuddyID is the ID its callbacks carry.
type BuddyRequested struct {
	Addr     netip.AddrPort
	UserHash wire.Hash
	BuddyID  wire.Hash
}

// CallbackRequested asks the engine to pass a downloader's
// KADEMLIA_CALLBACK_REQ to the client we serve, as OP_CALLBACK.
type CallbackRequested struct {
	BuddyID wire.Hash
	Hash    wire.Hash
	// Addr is the downloader's IP and TCP port.
	Addr netip.AddrPort
}

func (Buddy) isMessage()           {}
func (BuddyFound) isEvent()        {}
func (BuddyRequested) isEvent()    {}
func (CallbackRequested) isEvent() {}

type buddySearch struct {
	isDue bool
	next  time.Time
}

// buddyTarget is the ID a buddy lookup looks for and callbacks carry: our
// Kad ID inverted.
func (c *core) buddyTarget() wire.Hash {
	var t wire.Hash
	for i := range t {
		t[i] = ^c.id[i]
	}
	return t
}

// needsBuddy: nobody can reach us over TCP or UDP, so only a buddy can
// pass callbacks on (ClientList.cpp:686).
func (c *core) needsBuddy() bool {
	return c.firewall.isFirewalled() && c.udp.isFirewalledNow()
}

// runBuddySearch is the buddy part of CKademlia::Process and
// CClientList::Process, run each second while connected.
func (c *core) runBuddySearch(now time.Time) {
	b := &c.buddySearch
	if !now.Before(b.next) {
		b.isDue = true
		b.next = now.Add(buddySearchGap)
	}
	if !c.needsBuddy() || c.buddy.IsConnected || c.buddy.IsConnecting || !b.isDue {
		return
	}
	b.isDue = false
	if c.startLookup(buddyLookup, c.buddyTarget(), 0, now) == nil {
		b.isDue = true
	}
}

// setBuddy takes the engine's latest buddy state. A lost buddy is looked
// for again at once; a new buddy address is published at once
// (CKnownFile::PublishSrc).
func (c *core) setBuddy(b Buddy) {
	wasLinked := c.buddy.IsConnected || c.buddy.IsConnecting
	if wasLinked && !b.IsConnected && !b.IsConnecting && c.needsBuddy() {
		c.buddySearch.isDue = true
	}
	if b.Addr.IsValid() && b.Addr.Addr() != c.buddy.Addr.Addr() {
		for _, p := range c.publishes {
			p.next = time.Time{}
		}
	}
	c.buddy = b
}

// onFindBuddyReq is ProcessFindBuddyRequest (KademliaUDPListener.cpp:1446):
// only a node that others reach over TCP and UDP, and has no buddy yet,
// can serve.
func (c *core) onFindBuddyReq(from netip.AddrPort, p kadwire.FindBuddyReq) {
	if c.firewall.isFirewalled() || !c.udp.isOpen() || c.buddy.IsConnected {
		return
	}
	res := kadwire.FindBuddyRes{Target: p.Target, UserHash: c.userHash, TCPPort: c.tcpPort}
	if c.reply.key != 0 {
		res.HasOptions, res.Options = true, connectOptions
	}
	c.send(from, res)
	c.out.requests = append(c.out.requests, BuddyRequested{
		Addr: netip.AddrPortFrom(from.Addr(), p.TCPPort), UserHash: p.UserHash, BuddyID: p.Target,
	})
}

func (c *core) onFindBuddyRes(from netip.AddrPort, p kadwire.FindBuddyRes) {
	if c.rpcs.match(from, rpcFindBuddy, wire.Hash{}) == nil || p.Target != c.buddyTarget() {
		return
	}
	c.out.requests = append(c.out.requests, BuddyFound{
		Addr: netip.AddrPortFrom(from.Addr(), p.TCPPort), UserHash: p.UserHash, CryptOptions: p.Options,
	})
}

// onCallbackReq is ProcessCallbackRequest (KademliaUDPListener.cpp:1510);
// like aMule we do not check the buddy ID, the client we serve does.
func (c *core) onCallbackReq(from netip.AddrPort, p kadwire.CallbackReq) {
	if c.buddy.IsConnected {
		c.out.requests = append(c.out.requests, CallbackRequested{
			BuddyID: p.BuddyID, Hash: p.Hash, Addr: netip.AddrPortFrom(from.Addr(), p.TCPPort),
		})
	}
}

// sendFindBuddy is CSearch::StorePacket for FINDBUDDY (Search.cpp:771).
func (c *core) sendFindBuddy(l *lookup, cand *candidate, now time.Time) {
	if l.answers > buddyTotal {
		l.stop(now)
		return
	}
	c.sendTo(cand.Node, kadwire.FindBuddyReq{Target: l.target, UserHash: c.userHash, TCPPort: c.tcpPort})
	c.rpcs.add(&rpc{kind: rpcFindBuddy, node: cand.Node, sent: now, lookup: l})
	l.answers++
}
