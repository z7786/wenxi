package engine

import (
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/kad"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
)

// aMule BaseClient.h:492-494 and ClientTCPSocket.cpp:144.
const (
	buddyPingGap = 10 * time.Minute // SendBuddyPingPong: one ping every 10 min
	// AllowIncomeingBuddyPingPong: a ping within 13 min of the last one
	// goes unanswered.
	buddyPongGap     = 13 * time.Minute
	buddyIdleTimeout = connectTimeout + 15*time.Minute
	// incomingBuddyLife is how long a client we accepted as buddy has to
	// connect; aMule keeps it until some buddy links, we bound it.
	incomingBuddyLife = 10 * time.Minute
	// directCallbackGap: one direct callback per IP every 3 minutes
	// (CClientList::AllowCallbackRequest).
	directCallbackGap = 3 * time.Minute
	// connectOptions are ours as a direct callback request carries them:
	// obfuscation supported and requested.
	connectOptions byte = 0x03
)

// buddy is aMule's CClientList buddy (ClientList.cpp:560-720): one TCP link
// to an open client that passes callbacks on to us while nobody can reach
// us, or from a firewalled client whose callbacks we pass on.
type buddy struct {
	conn      *conn
	isServing bool
	// id is the buddy ID of the client we serve, which its reasks carry.
	id       wire.Hash
	lastPing time.Time
	// candidates are open nodes that agreed to be our buddy, tried one at
	// a time.
	candidates []kad.BuddyFound
	incoming   map[netip.Addr]incomingBuddy
}

// incomingBuddy is a firewalled client we told we would serve.
type incomingBuddy struct {
	user  wire.Hash
	id    wire.Hash
	added time.Time
}

func (e *Engine) onBuddyFound(f kad.BuddyFound) {
	for _, c := range e.buddy.candidates {
		if c.Addr == f.Addr {
			return
		}
	}
	e.buddy.candidates = append(e.buddy.candidates, f)
	e.startBuddyLink()
}

// startBuddyLink connects to the next candidate while we have no link.
func (e *Engine) startBuddyLink() {
	for e.buddy.conn == nil && len(e.buddy.candidates) > 0 {
		f := e.buddy.candidates[0]
		e.buddy.candidates = e.buddy.candidates[1:]
		c := e.connByEndpoint(f.Addr)
		if c == nil {
			if len(e.conns) >= maxConnections {
				return
			}
			c = e.openPeerConn(f.Addr, f.UserHash, wire.CanObfuscate(f.CryptOptions, f.UserHash))
		}
		e.buddy.conn, e.buddy.isServing = c, false
		e.kad.Post(kad.Buddy{IsConnecting: true})
		if c.isHandshaken() {
			e.onBuddyHandshake(c)
		}
	}
}

// onBuddyHandshake links a connection that completed its handshake: the
// candidate we connected to, or a client we accepted coming in.
func (e *Engine) onBuddyHandshake(c *conn) {
	b := &e.buddy
	switch {
	case c == b.conn && !b.isServing:
		b.candidates = nil
	case b.conn == nil && !c.isOutgoing:
		in, ok := b.incoming[c.remote.Addr()]
		if !ok || in.user != c.session.Capabilities().UserHash {
			return
		}
		b.conn, b.isServing, b.id = c, true, in.id
		clear(b.incoming)
	default:
		return
	}
	b.lastPing = e.now()
	c.session.SetIdleTimeout(buddyIdleTimeout)
	e.kad.Post(kad.Buddy{IsConnected: true, Addr: e.buddyAddr()})
}

func (e *Engine) onBuddyConnClosed(c *conn) {
	if c != e.buddy.conn {
		return
	}
	e.buddy.conn, e.buddy.isServing = nil, false
	e.kad.Post(kad.Buddy{})
	e.startBuddyLink()
}

// removeBuddyLink ends the link but not the connection, which may carry
// transfers; like any other it now closes when idle.
func (e *Engine) removeBuddyLink() {
	c := e.buddy.conn
	e.buddy.conn, e.buddy.isServing = nil, false
	c.session.SetIdleTimeout(connectTimeout)
	e.kad.Post(kad.Buddy{})
}

// buddyAddr is our buddy's IP and UDP port while it serves us: what the
// hello and the Kad source we publish tell downloaders.
func (e *Engine) buddyAddr() netip.AddrPort {
	c := e.buddy.conn
	if c == nil || e.buddy.isServing || !c.isHandshaken() {
		return netip.AddrPort{}
	}
	return netip.AddrPortFrom(c.remote.Addr(), c.session.Capabilities().UDPPort)
}

// runBuddy runs once a second: it pings our buddy and drops a link that
// lost its reason (ClientList.cpp:650-720).
func (e *Engine) runBuddy(now time.Time) {
	b := &e.buddy
	for ip, in := range b.incoming {
		if now.Sub(in.added) >= incomingBuddyLife {
			delete(b.incoming, ip)
		}
	}
	c := b.conn
	if c == nil || !c.isHandshaken() {
		return
	}
	status := e.kadStatus
	switch {
	case status.Nodes == 0:
		e.removeBuddyLink()
	case b.isServing && c.session.Capabilities().ClientID == 0:
		e.removeBuddyLink()
	case b.isServing:
	case !status.IsFirewalled || !status.IsUDPFirewalled:
		e.removeBuddyLink()
	case now.Sub(b.lastPing) >= buddyPingGap:
		b.lastPing = now
		e.sendPacket(c, client.BuddyPing{}, wire.Hash{}, 0)
	}
}

func (e *Engine) onBuddyPing(c *conn) {
	b := &e.buddy
	now := e.now()
	if c != b.conn || !b.isServing || c.session.Capabilities().KadVersion == 0 || now.Sub(b.lastPing) < buddyPongGap {
		return
	}
	b.lastPing = now
	e.sendPacket(c, client.BuddyPong{}, wire.Hash{}, 0)
}

func (e *Engine) onBuddyPong(c *conn) {
	if c == e.buddy.conn && !e.buddy.isServing {
		e.buddy.lastPing = e.now()
	}
}

// onCallbackRequested passes a downloader's Kad callback request to the
// client we serve.
func (e *Engine) onCallbackRequested(r kad.CallbackRequested) {
	if c := e.buddy.conn; c != nil && e.buddy.isServing && c.isHandshaken() {
		e.sendPacket(c, client.Callback{BuddyID: r.BuddyID, File: r.Hash, Endpoint: r.Addr}, wire.Hash{}, 0)
	}
}

// onCallback is OP_CALLBACK (ClientTCPSocket.cpp:1584): a downloader
// reached our buddy and wants a file we have, so we connect to it. The
// buddy ID is our Kad ID inverted, as eMule reads our TAG_BUDDYHASH; aMule
// reads it with its 32-bit words swapped (see kad.parseBuddyID), so that
// form is accepted too.
func (e *Engine) onCallback(p client.Callback) {
	if e.kad == nil {
		return
	}
	target := e.kad.ID()
	for i := range target {
		target[i] = ^target[i]
	}
	if p.BuddyID != target && p.BuddyID != wire.Hash(kadwire.BuildID(nil, target)) {
		return
	}
	if e.runByHash[p.File] == nil || !p.Endpoint.Addr().Is4() || p.Endpoint.Port() == 0 {
		return
	}
	if e.connByEndpoint(p.Endpoint) == nil && len(e.conns) < maxConnections {
		e.openPeerConn(p.Endpoint, wire.Hash{}, false)
	}
}

// onReaskCallbackUDP passes a downloader's UDP reask of the client we serve
// over our link (ClientUDPSocket.cpp:143). A downloader on IPv6 is passed
// on only to a client that announced an IPv6 address of its own: another
// could not answer it, and aMule drops such a reask
// (ClientTCPSocket.cpp:1891).
func (e *Engine) onReaskCallbackUDP(from netip.AddrPort, p client.ReaskCallbackUDP) {
	b := &e.buddy
	if b.conn == nil || !b.isServing || !b.conn.isHandshaken() || p.BuddyID != b.id {
		return
	}
	if from.Addr().Is6() && !b.conn.session.Capabilities().IPv6.IsValid() {
		return
	}
	e.sendPacket(b.conn, client.ReaskCallbackTCP{Endpoint: from, Ping: p.Ping}, wire.Hash{}, 0)
}

// onReaskCallbackTCP answers, over UDP, a reask our buddy passed on
// (ClientTCPSocket.cpp:1649).
func (e *Engine) onReaskCallbackTCP(c *conn, p client.ReaskCallbackTCP) {
	if c == e.buddy.conn && !e.buddy.isServing {
		e.onReask(p.Endpoint, p.Ping)
	}
}

// canDirectCallback is aMule's direct UDP callback condition
// (BaseClient.cpp:1127): nobody reaches our TCP port, a UDP test showed
// that anybody reaches our Kad port.
func (e *Engine) canDirectCallback() bool {
	s := e.kadStatus
	return e.kad != nil && s.IsFirewalled && !s.IsUDPFirewalled && s.IsUDPVerified
}

// requestDirectCallback asks a source that takes direct callbacks, at its
// Kad port, to connect to us (BaseClient.cpp:1497-1516).
func (e *Engine) requestDirectCallback(to netip.AddrPort, user wire.Hash, canObfuscate bool) {
	e.sendPeerDatagram(to, client.DirectCallbackReq{
		TCPPort: uint16(e.tcpPort), UserHash: e.self.UserHash, ConnectOptions: connectOptions,
	}, user, canObfuscate)
}

// onDirectCallbackReq connects to a downloader that asked us directly, as
// ClientUDPSocket.cpp:277 does while Kad sees us firewalled.
func (e *Engine) onDirectCallbackReq(from netip.AddrPort, p client.DirectCallbackReq) {
	now := e.now()
	for ip, at := range e.directCallbacks {
		if now.Sub(at) >= directCallbackGap {
			delete(e.directCallbacks, ip)
		}
	}
	if e.kad == nil || !e.kadStatus.IsFirewalled || p.TCPPort == 0 {
		return
	}
	if _, ok := e.directCallbacks[from.Addr()]; ok {
		return
	}
	e.directCallbacks[from.Addr()] = now
	endpoint := netip.AddrPortFrom(from.Addr(), p.TCPPort)
	if e.connByEndpoint(endpoint) != nil || len(e.conns) >= maxConnections {
		return
	}
	e.openPeerConn(endpoint, p.UserHash, wire.CanObfuscate(p.ConnectOptions, p.UserHash))
}
