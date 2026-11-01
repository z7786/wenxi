package engine

import (
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/kad"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

// Kad version 7 takes the TCP firewall acknowledgement over TCP
// (ClientList.cpp:590); version 6 is the first that can run a UDP test
// (BaseClient.cpp:2905).
const (
	versionTCPFirewallAck = 7
	versionUDPCheck       = 6
)

// kadCheck is why we opened a connection for Kad: to show a node that its
// TCP port is open (udp nil), or to have a client send us a UDP test.
type kadCheck struct {
	kadPort uint16
	udp     *kad.UDPCheck
	isSent  bool
}

func (e *Engine) onKadMessage(m kad.Event) {
	switch r := m.(type) {
	case kad.Status:
		e.kadStatus = r
	case kad.State:
		e.state.Kad = store.Kad(r)
	case kad.SourcesFound:
		e.onKadSources(r)
	case kad.Datagram:
		e.onDatagram(r.Addr, r.Data)
	case kad.FirewallCheck:
		e.startFirewallCheck(r)
	case kad.UDPCheck:
		e.startUDPCheck(r)
	case kad.BuddyFound:
		e.onBuddyFound(r)
	case kad.BuddyRequested:
		e.buddy.incoming[r.Addr.Addr()] = incomingBuddy{user: r.UserHash, id: r.BuddyID, added: e.now()}
	case kad.CallbackRequested:
		e.onCallbackRequested(r)
	}
}

// startFirewallCheck is ClientList::RequestTCP: connect to the asker, with
// obfuscation when it supports it, and acknowledge after the handshake.
// Over a connection already up, whoever opened it, aMule acknowledges at
// once without dialling (ClientList.cpp:874-887, BaseClient.cpp:1708-1716),
// and the asker counts it (ClientTCPSocket.cpp:2019-2025); skipping it
// would cost the asker an acknowledgement an aMule node gives.
func (e *Engine) startFirewallCheck(r kad.FirewallCheck) {
	if c := e.connByEndpoint(r.Addr); c != nil {
		if c.isHandshaken() {
			e.sendFirewallAck(c, r.KadPort)
		}
		return
	}
	if len(e.conns) >= maxConnections {
		return
	}
	c := e.openPeerConn(r.Addr, r.UserHash, wire.CanObfuscate(r.CryptOptions, r.UserHash))
	c.kadCheck = &kadCheck{kadPort: r.KadPort}
}

func (e *Engine) sendFirewallAck(c *conn, kadPort uint16) {
	if c.session.Capabilities().KadVersion >= versionTCPFirewallAck {
		e.sendPacket(c, client.KadFirewallAck{}, wire.Hash{}, 0)
		return
	}
	e.kad.Post(kad.FirewallAck{To: netip.AddrPortFrom(c.remote.Addr(), kadPort)})
}

// startUDPCheck is ClientList::DoRequestFirewallCheckUDP: a client we
// already talk to cannot show that strangers reach us.
func (e *Engine) startUDPCheck(r kad.UDPCheck) {
	for _, c := range e.conns {
		if !c.isServer && c.remote.Addr() == r.Addr.Addr() {
			e.kad.Post(kad.UDPCheckEnded{IP: r.Addr.Addr(), IsCancelled: true})
			return
		}
	}
	if len(e.conns) >= maxConnections {
		e.kad.Post(kad.UDPCheckEnded{IP: r.Addr.Addr(), IsCancelled: true})
		return
	}
	c := e.openPeerConn(r.Addr, wire.Hash{}, false)
	c.kadCheck = &kadCheck{udp: &r}
}

// onKadHandshake runs the Kad check a connection was opened for
// (BaseClient.cpp:1660-1672).
func (e *Engine) onKadHandshake(c *conn) {
	check := c.kadCheck
	if check == nil {
		return
	}
	if check.udp == nil {
		e.sendFirewallAck(c, check.kadPort)
		return
	}
	caps := c.session.Capabilities()
	if caps.KadVersion < versionUDPCheck || caps.KadPort == 0 {
		c.kadCheck = nil
		e.kad.Post(kad.UDPCheckEnded{IP: c.remote.Addr(), IsCancelled: true})
		return
	}
	check.isSent = true
	e.sendPacket(c, client.FirewallCheckUDPReq{InternPort: check.udp.InternPort, ExternPort: check.udp.ExternPort, Key: check.udp.Key}, wire.Hash{}, 0)
}

// onKadConnClosed ends a UDP test whose answer did not come while the
// connection lasted: a failure once the request went out.
func (e *Engine) onKadConnClosed(c *conn) {
	check := c.kadCheck
	if check == nil {
		return
	}
	c.kadCheck = nil
	if check.udp != nil {
		e.kad.Post(kad.UDPCheckEnded{IP: c.remote.Addr(), IsCancelled: !check.isSent})
	}
}

// onKadPacket acts on the Kad packets a peer connection carries. The
// session sees them too, as activity.
func (e *Engine) onKadPacket(c *conn, p wire.Packet) {
	switch p := p.(type) {
	case client.KadFirewallAck:
		if e.kad != nil {
			e.kad.Post(kad.FirewallAckReceived{From: c.remote.Addr()})
		}
	case client.FirewallCheckUDPReq:
		if e.kad != nil {
			e.kad.Post(kad.FirewallUDP{
				IP: c.remote.Addr(), InternPort: p.InternPort, ExternPort: p.ExternPort, Key: p.Key,
				IsKnown: len(c.session.Files()) > 0 || c.session.IsUploading(),
			})
		}
	case client.BuddyPing:
		e.onBuddyPing(c)
	case client.BuddyPong:
		e.onBuddyPong(c)
	case client.Callback:
		e.onCallback(p)
	case client.ReaskCallbackTCP:
		e.onReaskCallbackTCP(c, p)
	}
}
