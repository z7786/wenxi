package engine

import (
	"context"
	"log"
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/kad"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/obfuscation"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/peer"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/server"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transfer"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transport"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/upload"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
	serverwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/server"
)

const (
	kadVersion    = kadwire.Version
	maxDatagram   = 65536
	lookupTimeout = 30 * time.Second
)

// hostResolved is a server host name's IPv4 address; invalid when the
// lookup failed.
type hostResolved struct {
	host string
	addr netip.Addr
}

// runServer performs the server's actions in order.
func (e *Engine) runServer(actions []server.Action) {
	for _, action := range actions {
		switch a := action.(type) {
		case server.Close:
			if c := e.serverConnByEndpoint(a.Server); c != nil {
				e.closeConn(c, "server closed")
			}
		case server.Dial:
			e.openConn(a.Server, true, wire.Hash{}, a.ObfuscationPort)
		case server.Send:
			if c := e.serverConnByEndpoint(a.To); c != nil {
				e.sendPacket(c, a.Packet, wire.Hash{}, 0)
			}
		case server.Datagram:
			data := a.Packet.Build(nil)
			if a.Key != 0 {
				data = obfuscation.BuildServerDatagram(data, a.Key, e.ports.Rand.Uint32())
			}
			e.serverUDP.WriteTo(data, a.To)
		case server.Callback:
			if e.connByEndpoint(a.Endpoint) == nil && len(e.conns) < maxConnections {
				canObfuscate := a.CanObfuscate && !e.hasOtherUser(a.Endpoint, a.UserHash)
				e.openPeerConn(a.Endpoint, a.UserHash, canObfuscate)
			}
		case server.Resolve:
			t := e.transport
			e.startLeaf(func() { e.runLookup(t, a.Host) })
		case server.SourcesFound:
			channel := transfer.ChannelServer
			if a.IsGlobal {
				channel = transfer.ChannelGlobalServer
			}
			if r := e.downloadByHash(a.File); r != nil {
				e.runTransferActions(r, r.transfer.OnSourcesFound(toServerSources(a.Sources), channel, e.now()))
			}
		case server.IDChanged:
			// A LowID server's view of our address is the best we get, as
			// aMule's SetPublicIP from OP_IDCHANGE (ServerSocket.cpp:380-382).
			switch {
			case !wire.IsLowID(a.ClientID):
				e.publicIP = wire.ToAddr(a.ClientID)
			case isPublicIPv4(a.ReportedIP):
				e.publicIP = a.ReportedIP
			}
		case server.MessageReceived:
			log.Printf("engine: server message: %s", a.Text)
		}
	}
}

// runLookup is a leaf that resolves a server's host name. Through a socks5h
// Proxy it fails, and the server waits unresolved (ADR-0006).
func (e *Engine) runLookup(t transport.Transport, host string) {
	ctx, cancel := context.WithTimeout(e.ctx, lookupTimeout)
	addrs, err := t.LookupHost(ctx, host)
	cancel()
	var addr netip.Addr
	if err == nil && len(addrs) > 0 {
		addr = addrs[0]
	} else {
		log.Printf("engine: server host %s: %v", host, err)
	}
	e.send(e.ctx, hostResolved{host, addr})
}

// updateLearned puts what an earlier Engine Process learned about each
// listed server back on its entry; names and preferences stay as the lists
// say. A saved server no list names any more is forgotten: Kelpie learns
// servers only from the caller's lists.
func updateLearned(entries []server.Entry, saved []store.Server) []server.Entry {
	for i, e := range entries {
		j := slices.IndexFunc(saved, func(s store.Server) bool {
			if e.Host != "" {
				return s.Host == e.Host && s.Port == e.Endpoint.Port()
			}
			return s.Host == "" && s.Endpoint == e.Endpoint
		})
		if j < 0 {
			continue
		}
		s := saved[j]
		entries[i].Failures, entries[i].Ping, entries[i].PingedAt = s.Failures, s.Ping, s.PingedAt
		entries[i].Users, entries[i].Files, entries[i].SoftFiles = s.Users, s.Files, s.SoftFiles
		entries[i].UDPFlags = s.UDPFlags
		entries[i].TCPObfuscationPort, entries[i].UDPObfuscationPort = s.TCPObfuscationPort, s.UDPObfuscationPort
		entries[i].UDPKey, entries[i].UDPKeyIP = s.UDPKey, s.UDPKeyIP
	}
	return entries
}

func toStoreServers(entries []server.Entry) []store.Server {
	var servers []store.Server
	for _, e := range entries {
		s := store.Server{
			Endpoint:           e.Endpoint,
			Failures:           e.Failures,
			Ping:               e.Ping,
			Users:              e.Users,
			Files:              e.Files,
			SoftFiles:          e.SoftFiles,
			UDPFlags:           e.UDPFlags,
			TCPObfuscationPort: e.TCPObfuscationPort,
			UDPObfuscationPort: e.UDPObfuscationPort,
			PingedAt:           e.PingedAt,
			UDPKey:             e.UDPKey,
			UDPKeyIP:           e.UDPKeyIP,
		}
		if e.Host != "" {
			s.Endpoint, s.Host, s.Port = netip.AddrPort{}, e.Host, e.Endpoint.Port()
		}
		servers = append(servers, s)
	}
	return servers
}

// hasOtherUser tells whether a Hello from endpoint named a user other than
// user. aMule then connects plain, since it cannot tell which hash is true
// (ServerSocket.cpp:527-536).
func (e *Engine) hasOtherUser(endpoint netip.AddrPort, user wire.Hash) bool {
	hasOther := false
	for key, target := range e.uploadEndpoints {
		if target.endpoint != endpoint {
			continue
		}
		if key.user == user {
			return false
		}
		hasOther = true
	}
	return hasOther
}

// hasServerConn tells whether a server connection, logged in or not, goes
// to ip.
func (e *Engine) hasServerConn(ip netip.Addr) bool {
	for _, c := range e.conns {
		if c.isServer && c.remote.Addr() == ip {
			return true
		}
	}
	return false
}

func (e *Engine) serverConnByEndpoint(addr netip.AddrPort) *conn {
	for _, c := range e.conns {
		if c.isServer && c.remote == addr {
			return c
		}
	}
	return nil
}

func toServerSources(found []server.Source) []transfer.Source {
	var sources []transfer.Source
	for _, f := range found {
		src := transfer.Source{Endpoint: f.Endpoint, UserHash: f.UserHash, CanObfuscate: f.CanObfuscate}
		if f.IsLowID {
			src = transfer.Source{ClientID: f.ClientID, Server: f.Server, UserHash: f.UserHash}
		}
		sources = append(sources, src)
	}
	return sources
}

func (e *Engine) requestServerCallback(clientID uint32) {
	e.runServer(e.server.RequestCallback(clientID, e.now()))
}

func toKadCallback(a transfer.RequestKadCallback, file wire.Hash) kad.Callback {
	return kad.Callback{Buddy: a.Buddy, BuddyID: a.BuddyID, Hash: file}
}

// buildWanted lists every running Transfer for the server and for Kad,
// which decide themselves what to search and offer: incomplete files until
// they have enough sources, files with verified parts. The source count is
// the last Progress, at most a second old.
func (e *Engine) buildWanted() ([]server.Wanted, kad.Wanted) {
	var toServer []server.Wanted
	var toKad kad.Wanted
	for _, r := range e.runs {
		if r.transfer == nil {
			continue
		}
		isComplete, isShared := r.share.Parts.IsFull(), r.share.Parts.Count() > 0
		toServer = append(toServer, server.Wanted{
			File:       r.file.Hash,
			Size:       uint64(r.file.Size),
			Name:       r.file.Name,
			IsComplete: isComplete,
			IsShared:   isShared,
			Sources:    r.progress.Peers,
		})
		toKad = append(toKad, kad.File{
			Hash:       r.file.Hash,
			Size:       r.file.Size,
			Sources:    r.progress.Peers,
			IsComplete: isComplete,
			IsShared:   isShared,
		})
	}
	return toServer, toKad
}

func (e *Engine) onKadSources(found kad.SourcesFound) {
	if r := e.downloadByHash(found.Hash); r != nil {
		e.runTransferActions(r, r.transfer.OnSourcesFound(toKadSources(found.Sources), transfer.ChannelKad, e.now()))
	}
}

func (e *Engine) sendDatagram(to netip.AddrPort, data []byte) {
	if e.kad != nil {
		e.kad.Post(kad.Datagram{Addr: to, Data: data})
		return
	}
	// e.udp is nil only if another program took the port while Kad let go
	// of it.
	if e.udp != nil {
		e.udp.WriteTo(data, to)
	}
}

// runUDPReader serves a UDP socket the engine owns: the server UDP socket,
// and the eD2k one while Kad does not own it. It takes the socket rather
// than reading e.udp, which the hub replaces when Kad turns on or off.
func (e *Engine) runUDPReader(socket transport.PacketConn, isServer bool) {
	buf := make([]byte, maxDatagram)
	for {
		n, from, err := socket.ReadFrom(buf)
		if err != nil {
			return
		}
		if !e.send(e.ctx, datagramReceived{from, append([]byte(nil), buf[:n]...), isServer}) {
			return
		}
	}
}

// onServerDatagram opens a datagram from a server, obfuscated when the
// server owes us an obfuscated answer (ServerUDPSocket.cpp:59-117).
func (e *Engine) onServerDatagram(from netip.AddrPort, data []byte) {
	if key := e.server.UDPKeyByAddr(from); key != 0 {
		if packet, ok := obfuscation.ParseServerDatagram(data, key); ok {
			data = packet
		}
	}
	frame, err := wire.ParseDatagram(data)
	if err != nil || frame.Protocol != wire.ProtocolEDonkey {
		return
	}
	if p, err := serverwire.ParseUDP(frame.Protocol, frame.Opcode, frame.Body); err == nil {
		e.runServer(e.server.OnPacket(from, p, e.now()))
	}
}

// onDatagram routes eD2k client UDP: reasks to the upload queue and the
// downloads.
func (e *Engine) onDatagram(from netip.AddrPort, data []byte) {
	if packet, ok := obfuscation.ParsePeerDatagram(data, e.self.UserHash, from.Addr()); ok {
		data = packet
	}
	frame, err := wire.ParseDatagram(data)
	if err != nil || frame.Protocol != wire.ProtocolEMule {
		return
	}
	p, err := client.ParseUDP(frame.Protocol, frame.Opcode, frame.Body)
	if err != nil {
		return
	}
	switch p := p.(type) {
	case client.ReaskFilePing:
		e.onReask(from, p)
	case client.ReaskCallbackUDP:
		e.onReaskCallbackUDP(from, p)
	case client.DirectCallbackReq:
		e.onDirectCallbackReq(from, p)
	case client.ReaskAck, client.QueueFull, client.FileNotFound:
		// The answer does not name the file: only the download reasking its
		// sender takes it.
		for _, r := range slices.Clone(e.runs) {
			if e.downloadByHash(r.file.Hash) != nil {
				e.runTransferActions(r, r.transfer.OnReaskAnswered(from, p, e.now()))
			}
		}
	}
}

func (e *Engine) onReask(from netip.AddrPort, ping client.ReaskFilePing) {
	var reply wire.Packet
	var user wire.Hash
	switch a := e.queue.OnReask(from.Addr(), from.Port(), ping.Hash, e.now()).(type) {
	case upload.ReaskAck:
		ack := client.ReaskAck{Rank: uint16(min(a.Rank, 0xFFFF))}
		if r := e.runByHash[ping.Hash]; ping.HasParts && r != nil {
			ack.HasParts, ack.Parts = true, peer.ToStatus(r.share)
		}
		reply, user = ack, a.User
	case upload.FileNotFound:
		reply, user = client.FileNotFound{}, a.User
	case upload.QueueFull:
		reply = client.QueueFull{}
	default:
		return
	}
	canObfuscate := e.uploadEndpoints[uploadKey{user, from.Addr()}].canObfuscate
	e.sendPeerDatagram(from, reply, user, canObfuscate)
}

// sendPeerDatagram obfuscates p for the client with user hash user when it
// supports obfuscation and we know our public IPv4 address, which keys it;
// we always request obfuscation, so that is aMule's
// ShouldReceiveCryptUDPPackets (BaseClient.cpp:2609, MuleUDPSocket.cpp:269).
func (e *Engine) sendPeerDatagram(to netip.AddrPort, p wire.Packet, user wire.Hash, canObfuscate bool) {
	data := p.Build(nil)
	if canObfuscate && user != (wire.Hash{}) && e.publicIP.Is4() {
		data = obfuscation.BuildPeerDatagram(data, user, e.publicIP, e.ports.Rand.Uint32())
	}
	e.sendDatagram(to, data)
}
