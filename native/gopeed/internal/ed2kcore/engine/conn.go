package engine

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"maps"
	"math/rand/v2"
	"net"
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/disk"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/kad"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/obfuscation"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/peer"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transfer"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transport"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/upload"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
	serverwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/server"
)

const (
	// uploadBufferSize is how much upload data a connection may have read
	// and not yet written before its next block is read: aMule's
	// 5*EMBLOCKSIZE+1 (UploadDiskIOThread.cpp:205-212).
	uploadBufferSize = 5 * piece.BlockSize
	// maxWriterBacklog bounds the packets waiting beyond a writer's
	// channel; a peer that does not read past it is dropped. aMule has no
	// such limit; upload data alone stays far below it under
	// uploadBufferSize.
	maxWriterBacklog = 1024
	// maxIncomingHandshakes bounds accepted connections still waiting for
	// their first bytes; further ones wait in the kernel's backlog, as aMule
	// stops accepting under TooManySockets (ListenSocket.cpp:93). The value
	// is eMule's half-open default (MaxHalfConnections, Preferences.cpp:2038).
	maxIncomingHandshakes = 50
)

// conn is one TCP connection: to a peer, or to the server.
type conn struct {
	id           uint64
	ctx          context.Context
	cancel       context.CancelFunc
	net          net.Conn
	remote       netip.AddrPort
	isServer     bool
	isOutgoing   bool
	isObfuscated bool
	// control and data feed the writer: upload data waits in data so that
	// a control packet never queues behind it, as aMule keeps a control
	// and a standard queue per socket (EMSocket.cpp:338-360).
	control *leafQueue[outItem]
	data    *leafQueue[outItem]
	// session is the peer's state machine, from the dial on; nil on a server
	// connection. Its Files are the downloads this connection serves.
	session *peer.Session
	// uploadFile is the file the peer queued for with us, and uploadParts
	// what it said it has of it, for answering Source Exchange.
	uploadFile  wire.Hash
	uploadParts piece.Set
	// uploadBlocks are requested blocks not yet read; uploadBuffered counts
	// the upload bytes being read or waiting to be written.
	uploadBlocks   []diskJob
	uploadBuffered int64
	// kadCheck is set on a connection opened for a Kad check until the
	// check is done with it; a TCP check keeps it after the acknowledgement,
	// as the node we acknowledged may be dialling us for a check of its own
	// (closeDuplicate).
	kadCheck *kadCheck
	// isRefused: the dial was refused or never answered, which alone
	// counts against a server (server.OnDisconnected). It is kept because
	// closeConn, which reports the close, sees only the reason text.
	isRefused bool
	// handshakenAt is when the engine acted on the handshake, which is
	// later than the session completes it: within the Output that carries
	// HandshakeCompleted the transfers do not know the peer yet. Its age
	// tells a peer that dialled us while we dialled it from one that came
	// back after losing an older connection; see closeDuplicate.
	handshakenAt time.Time
	isClosed     bool
}

// outItem is one packet for a writer. Payload counts upload data, for the
// queue, the transfer and the ledger once it is written.
type outItem struct {
	packet  wire.Packet
	file    wire.Hash
	payload int64
}

func (e *Engine) addConn(remote netip.AddrPort, isServer, isOutgoing bool) *conn {
	e.nextConn++
	ctx, cancel := context.WithCancel(e.ctx)
	c := &conn{
		id:         e.nextConn,
		ctx:        ctx,
		cancel:     cancel,
		remote:     netip.AddrPortFrom(remote.Addr().Unmap(), remote.Port()),
		isServer:   isServer,
		isOutgoing: isOutgoing,
		control:    buildLeafQueue[outItem](e.caps.writer),
		data:       buildLeafQueue[outItem](e.caps.writer),
	}
	e.conns[c.id] = c
	return c
}

// openConn dials remote from a leaf; the hub learns the result from
// connOpened. A non-zero obfuscateFor is the peer's user hash, and the
// connection is obfuscated with it. A server connection with a non-zero
// obfuscationPort is dialled on that port and obfuscated by key agreement.
func (e *Engine) openConn(remote netip.AddrPort, isServer bool, obfuscateFor wire.Hash, obfuscationPort uint16) *conn {
	c := e.addConn(remote, isServer, true)
	c.isObfuscated = obfuscateFor != wire.Hash{} || obfuscationPort != 0
	if !isServer {
		c.session = peer.BuildOutgoing(c.remote)
		e.recentConnects = append(e.recentConnects, e.now())
	}
	keyPart := [4]byte(binary.LittleEndian.AppendUint32(nil, e.ports.Rand.Uint32()))
	var secret [16]byte
	binary.LittleEndian.PutUint64(secret[:8], e.ports.Rand.Uint64())
	binary.LittleEndian.PutUint64(secret[8:], e.ports.Rand.Uint64())
	random := buildLeafRandom(e.ports.Rand)
	dial := c.remote
	if obfuscationPort != 0 {
		dial = netip.AddrPortFrom(c.remote.Addr(), obfuscationPort)
	}
	if e.packetLog != nil {
		e.packetLog.Printf("open %s obfuscated=%t", dial, c.isObfuscated)
	}
	t := e.transport
	e.startLeaf(func() {
		ctx, cancel := context.WithTimeout(c.ctx, connectTimeout)
		netConn, err := t.OpenTCP(ctx, dial)
		cancel()
		switch {
		case err != nil:
		case obfuscationPort != 0:
			netConn, err = openObfuscated(c.ctx, netConn, func(c net.Conn) (net.Conn, error) {
				return obfuscation.OpenServer(c, secret, keyPart[0], random)
			})
		case obfuscateFor != wire.Hash{}:
			netConn, err = openObfuscated(c.ctx, netConn, func(c net.Conn) (net.Conn, error) {
				return obfuscation.OpenOutgoing(c, obfuscateFor, keyPart, random)
			})
		}
		if !e.send(c.ctx, connOpened{c.id, netConn, err}) && netConn != nil {
			netConn.Close()
		}
	})
	return c
}

// openPeerConn dials a client, obfuscated with its user hash when it can
// be.
func (e *Engine) openPeerConn(endpoint netip.AddrPort, user wire.Hash, canObfuscate bool) *conn {
	if !canObfuscate {
		user = wire.Hash{}
	}
	return e.openConn(endpoint, false, user, 0)
}

// openObfuscated runs an obfuscation handshake on a leaf. It closes the
// socket once ctx ends or connectTimeout passes, so the leaf does not outlive
// the connection; like the dial, it is timed by a context deadline.
func openObfuscated(ctx context.Context, netConn net.Conn, open func(net.Conn) (net.Conn, error)) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()
	stop := context.AfterFunc(ctx, func() { netConn.Close() })
	conn, err := open(netConn)
	if !stop() && err == nil {
		err = ctx.Err()
	}
	if err != nil {
		netConn.Close()
		return nil, err
	}
	return conn, nil
}

// uploadTarget is how to reach a peer waiting in our upload queue once its
// slot comes.
type uploadTarget struct {
	endpoint     netip.AddrPort
	canObfuscate bool
}

// refreshUploadEndpoints forgets peers that are neither connected nor known
// to the upload queue: nothing will ask to reach them.
func (e *Engine) refreshUploadEndpoints() {
	connected := map[uploadKey]bool{}
	for _, c := range e.conns {
		if c.isHandshaken() {
			connected[uploadKey{c.session.Capabilities().UserHash, c.remote.Addr()}] = true
		}
	}
	maps.DeleteFunc(e.uploadEndpoints, func(k uploadKey, _ uploadTarget) bool {
		return !connected[k] && !e.queue.HasPeer(k.user, k.ip)
	})
}

// runAcceptor takes random from the hub, since it cannot share the hub's;
// each connection's leaf gets one of its own from it.
func (e *Engine) runAcceptor(random *rand.Rand) {
	self := e.self.UserHash
	handshakes := make(chan struct{}, maxIncomingHandshakes)
	for {
		select {
		case handshakes <- struct{}{}:
		case <-e.ctx.Done():
			return
		}
		netConn, remote, err := e.listener.Accept()
		if err != nil {
			return
		}
		connRandom := buildLeafRandom(random)
		e.startLeaf(func() {
			e.runIncoming(netConn, remote, self, connRandom)
			<-handshakes
		})
	}
}

// runIncoming waits for an accepted connection's first bytes, which tell
// whether the peer obfuscates, before the hub sees the connection.
func (e *Engine) runIncoming(netConn net.Conn, remote netip.AddrPort, self wire.Hash, random *rand.Rand) {
	conn, err := openObfuscated(e.ctx, netConn, func(c net.Conn) (net.Conn, error) {
		return obfuscation.OpenIncoming(c, self, random)
	})
	if err == nil && !e.send(e.ctx, connAccepted{conn, remote}) {
		netConn.Close()
	}
}

func (e *Engine) onConnAccepted(m connAccepted) {
	if len(e.conns) >= maxConnections {
		m.conn.Close()
		return
	}
	c := e.addConn(m.remote, false, false)
	c.net = m.conn
	e.startConnLeaves(c)
	c.session = peer.BuildIncoming(e.buildPeerConfig(c), c.remote, e.now())
}

func (e *Engine) onConnOpened(m connOpened) {
	c := e.conns[m.id]
	if c == nil {
		if m.conn != nil {
			m.conn.Close()
		}
		return
	}
	if m.err != nil {
		c.isRefused = transport.IsRefused(m.err)
		e.closeConn(c, toReason(m.err))
		return
	}
	c.net = m.conn
	e.startConnLeaves(c)
	if c.isServer {
		e.runServer(e.server.OnConnected(c.remote))
		return
	}
	e.runSession(c, c.session.OnOpened(e.buildPeerConfig(c), e.now()))
}

// startConnLeaves starts c's reader and writer. Server traffic is not
// rate limited, and neither is a peer connection from a server we are
// logged in or logging in to: that is the server's HighID probe, which a
// queue at the limiter could hold past the server's timer and so cost us
// the HighID (aMule ClientTCPSocket.cpp:167-178, #778).
func (e *Engine) startConnLeaves(c *conn) {
	parse := client.Parse
	if c.isServer {
		parse = serverwire.Parse
	}
	limiterIn, limiterOut := e.downloadLimiter, e.uploadLimiter
	if c.isServer || e.hasServerConn(c.remote.Addr()) {
		limiterIn, limiterOut = nil, nil
	}
	e.startLeaf(func() { e.runReader(c.ctx, c.id, c.remote, c.net, parse, limiterIn) })
	e.startLeaf(func() { e.runWriter(c.ctx, c.id, c.remote, c.net, c.control.items, c.data.items, limiterOut) })
}

func (e *Engine) buildPeerConfig(c *conn) peer.Config {
	server, serverID := e.server.Login()
	cfg := peer.Config{
		Self:        e.self,
		Version:     e.config.Version,
		ClientID:    toHelloID(serverID, e.kadStatus),
		PublicIP:    e.publicIP,
		Port:        uint16(e.tcpPort),
		UDPPort:     uint16(e.udpPort),
		Server:      server,
		Random:      e.ports.Rand,
		ShareByHash: e.shareByHash,
		SourcesByHash: func(file wire.Hash, parts piece.Set) []peer.Source {
			return e.buildPeerSources(file, c, parts)
		},
		CanAskSlot: e.canAskSlot,
	}
	if e.kad != nil {
		cfg.KadPort = e.kadStatus.UDPPort
		cfg.KadVersion = kadVersion
		if e.isFirewalled() {
			cfg.Buddy = e.buddyAddr()
		}
		cfg.HasDirectCallback = e.canDirectCallback()
	}
	return cfg
}

// toHelloID is the ID our Hello names, aMule's GetID (amule.cpp:3170-3187):
// Kad's word that peers reach us beats a LowID from the server, and a
// client that only a firewalled Kad connects is 1, which tells peers not to
// connect to it.
func toHelloID(serverID uint32, status kad.Status) uint32 {
	isKadConnected := status.Nodes > 0
	switch {
	case isKadConnected && !status.IsFirewalled && status.PublicIP.Is4():
		return wire.ToClientID(status.PublicIP)
	case serverID != 0:
		return serverID
	case isKadConnected && status.IsFirewalled:
		return 1
	}
	return 0
}

// countingReader counts the bytes of each frame for the rate limiter.
type countingReader struct {
	r io.Reader
	n int
}

func (c *countingReader) Read(b []byte) (int, error) {
	n, err := c.r.Read(b)
	c.n += n
	return n, err
}

// runReader is a connection's reader leaf: it decodes frames and posts
// them, blocking while the hub is busy so that TCP pushes back.
func (e *Engine) runReader(ctx context.Context, id uint64, remote netip.AddrPort, netConn net.Conn, parse func(protocol, opcode byte, body []byte) (wire.Packet, error), limiter *rateLimiter) {
	r := &countingReader{r: bufio.NewReaderSize(netConn, 64<<10)}
	for {
		frame, err := wire.ParseFrameFrom(r)
		if err == nil && limiter != nil {
			err = limiter.waitN(ctx, r.n)
		}
		r.n = 0
		var p wire.Packet
		if err == nil {
			p, err = parse(frame.Protocol, frame.Opcode, frame.Body)
		}
		if err != nil {
			e.send(ctx, connClosed{id, err})
			return
		}
		if e.packetLog != nil {
			e.packetLog.Printf("in  %s %s %d", remote, toPacketName(p), len(frame.Body))
		}
		if !e.send(ctx, packetReceived{id, p}) {
			return
		}
	}
}

// runWriter is a connection's writer leaf. It writes control packets before
// upload data, and lets them pass the rate limiter at once, ahead of the data
// already waiting there. It reports each written packet so the hub can count
// credit and uploaded bytes.
func (e *Engine) runWriter(ctx context.Context, id uint64, remote netip.AddrPort, netConn net.Conn, control, data <-chan outItem, limiter *rateLimiter) {
	var buf []byte
	for {
		var item outItem
		var ok bool
		select {
		case item, ok = <-control:
		default:
			select {
			case item, ok = <-control:
			case item, ok = <-data:
			case <-ctx.Done():
				return
			}
		}
		if !ok {
			return
		}
		buf = wire.BuildPacket(buf[:0], item.packet)
		switch {
		case limiter == nil:
		case item.payload == 0:
			limiter.addControl(len(buf))
		case limiter.waitN(ctx, len(buf)) != nil:
			return
		}
		if _, err := netConn.Write(buf); err != nil {
			netConn.Close()
			return
		}
		if e.packetLog != nil {
			e.packetLog.Printf("out %s %s %d", remote, toPacketName(item.packet), len(buf)-wire.HeaderSize)
		}
		if !e.send(ctx, packetSent{id, item.file, item.payload}) {
			return
		}
	}
}

// sendPacket queues p for c's writer; a non-zero payload marks upload data.
func (e *Engine) sendPacket(c *conn, p wire.Packet, file wire.Hash, payload int64) {
	switch {
	case c.isClosed:
	case len(c.control.backlog)+len(c.data.backlog) >= maxWriterBacklog:
		e.closeConn(c, "send queue full")
	case payload == 0:
		c.control.send(outItem{p, file, payload})
	default:
		c.data.send(outItem{p, file, payload})
	}
}

func (e *Engine) onPacketSent(m packetSent) {
	c := e.conns[m.id]
	if c == nil {
		return
	}
	now := e.now()
	if c.session != nil {
		c.session.OnSent(now)
	}
	if m.payload == 0 {
		c.control.onDone()
		return
	}
	c.data.onDone()
	c.uploadBuffered -= m.payload
	e.sendUploadReads(c)
	e.queue.OnSent(c.id, m.payload)
	if r := e.runByHash[m.file]; r != nil && r.transfer != nil {
		r.transfer.OnUploaded(m.payload, now)
	}
	if c.session != nil {
		e.ledger.OnTransferred(c.session.Capabilities().UserHash, c.remote.Addr(), m.payload, 0)
	}
}

// closeConn closes c at once and tells everyone who used it. A closed
// server connection is reported to the server only when the server did not
// ask for the close itself.
func (e *Engine) closeConn(c *conn, reason string) {
	if c.isClosed {
		return
	}
	c.isClosed = true
	if e.packetLog != nil {
		e.packetLog.Printf("close %s obfuscated=%t %s", c.remote, c.isObfuscated, reason)
	}
	delete(e.conns, c.id)
	c.cancel()
	if c.net != nil {
		c.net.Close()
	}
	close(c.control.items)
	close(c.data.items)
	now := e.now()
	if c.isServer {
		e.runServer(e.server.OnDisconnected(c.remote, c.isRefused, now))
		return
	}
	e.queue.OnConnectionGone(c.id)
	for _, event := range c.session.Stop().Events {
		e.onPeerEvent(c, event)
	}
	e.onKadConnClosed(c)
	e.onBuddyConnClosed(c)
	for _, h := range c.session.Files() {
		if r := e.runByHash[h]; r != nil && r.transfer != nil {
			e.removeTransferPeer(c, r, reason, now)
		}
	}
}

// removeTransferPeer tells r that c no longer serves it: as a peer gone once
// the transfer knows c from its handshake, as a failed connect before.
func (e *Engine) removeTransferPeer(c *conn, r *run, reason string, now time.Time) {
	if c.isHandshaken() {
		e.runTransferActions(r, r.transfer.OnPeerGone(c.id, reason, now))
	} else if c.isOutgoing {
		e.runTransferActions(r, r.transfer.OnConnectFailed(c.remote, reason, now))
	}
}

func (e *Engine) sortedConns() []*conn {
	conns := make([]*conn, 0, len(e.conns))
	for _, id := range slices.Sorted(maps.Keys(e.conns)) {
		conns = append(conns, e.conns[id])
	}
	return conns
}

// connByEndpoint is the oldest peer connection to endpoint.
func (e *Engine) connByEndpoint(endpoint netip.AddrPort) *conn {
	var found *conn
	for _, c := range e.conns {
		isMatch := !c.isServer && (c.isOutgoing && c.remote == endpoint || c.isHandshaken() && c.endpoint() == endpoint)
		if isMatch && (found == nil || c.id < found.id) {
			found = c
		}
	}
	return found
}

// endpoint is the peer's address with its listening port, as its hello said.
func (c *conn) isHandshaken() bool { return !c.handshakenAt.IsZero() }

func (c *conn) endpoint() netip.AddrPort {
	return netip.AddrPortFrom(c.remote.Addr(), c.session.Capabilities().Port)
}

func (e *Engine) onPacket(id uint64, p wire.Packet) {
	c := e.conns[id]
	if c == nil {
		return
	}
	if c.isServer {
		e.runServer(e.server.OnPacket(c.remote, p, e.now()))
		return
	}
	e.onKadPacket(c, p)
	if c.isClosed {
		return
	}
	e.runSession(c, c.session.OnPacket(p, e.now()))
}

// runSession performs a session's Output in its documented order.
func (e *Engine) runSession(c *conn, out peer.Output) {
	if c.isClosed {
		return
	}
	for _, p := range out.Send {
		e.sendPacket(c, p, wire.Hash{}, 0)
	}
	for _, event := range out.Events {
		if c.isClosed {
			return
		}
		e.onPeerEvent(c, event)
	}
	if out.Close != "" {
		e.closeConn(c, out.Close)
	}
}

func (e *Engine) onPeerEvent(c *conn, event peer.Event) {
	now := e.now()
	switch ev := event.(type) {
	case peer.HandshakeCompleted:
		e.ledger.OnHello(c.session.Capabilities().UserHash, now)
		e.onHandshake(c, ev)
	case peer.Identified:
		e.ledger.OnIdentified(c.session.Capabilities().UserHash, c.remote.Addr(), ev.PublicKey)
	case peer.StatusReceived:
		if r := e.downloadByHash(ev.File); r != nil {
			r.transfer.OnPeerParts(c.id, ev.Parts)
		}
	case peer.HashSetReceived:
		if r := e.downloadByHash(ev.File); r != nil {
			e.runTransferActions(r, r.transfer.OnHashSet(c.id, ev.Hashes))
			e.refreshShare(r)
		}
	case peer.FileRejected:
		e.onFileRejected(c, ev.File)
	case peer.Queued:
		if r := e.downloadByHash(ev.File); r != nil {
			e.runTransferActions(r, r.transfer.OnQueued(c.id, int(ev.Rank), now))
		}
	case peer.SlotAsked:
		e.onSlotAsked(c, ev.File)
	case peer.SlotGranted:
		e.onSlotGranted(c, ev.File)
	case peer.NoNeededParts:
		e.onNoNeededParts(c, ev.File)
	case peer.BlocksWanted:
		if r := e.downloadByHash(ev.File); r != nil {
			blocks, actions := r.transfer.Request(c.id, ev.Count, now)
			e.runSession(c, c.session.Request(ev.File, blocks))
			e.runTransferActions(r, actions)
		}
	case peer.BlockReceived:
		e.ledger.OnTransferred(c.session.Capabilities().UserHash, c.remote.Addr(), 0, ev.Payload)
		if r := e.downloadByHash(ev.File); r != nil {
			e.runTransferActions(r, r.transfer.OnBlockReceived(c.id, ev.Block, ev.Data, now))
		}
	case peer.UploadRequested:
		if r := e.downloadByHash(ev.File); r != nil && e.isReaskDue(r, c.session.Capabilities().UserHash) {
			e.addFile(c, r)
		}
		c.uploadFile, c.uploadParts = ev.File, ev.Parts
		e.runQueueActions(e.queue.OnRequest(c.id, toUploadPeer(c), ev.File, now))
	case peer.BlocksRequested:
		e.onBlocksRequested(c, ev)
	case peer.UploadCancelled:
		c.uploadFile = wire.Hash{}
		c.uploadBlocks = nil
		e.queue.OnConnectionGone(c.id)
	case peer.SourcesFound:
		if r := e.downloadByHash(ev.File); r != nil {
			e.runTransferActions(r, r.transfer.OnSourcesFound(toExchangeSources(ev.Sources), transfer.ChannelExchange, now))
		}
	case peer.RootReceived:
		if r := e.downloadByHash(ev.File); r != nil {
			r.transfer.OnRoot(c.id, ev.Root)
		}
	case peer.RecoveryReceived:
		if r := e.downloadByHash(ev.File); r != nil {
			e.runTransferActions(r, r.transfer.OnRecovery(c.id, ev.Part, ev.Root, ev.Entries, now))
		}
	case peer.RecoveryFailed:
		if r := e.downloadByHash(ev.File); r != nil {
			e.runTransferActions(r, r.transfer.OnRecoveryFailed(c.id, now))
		}
	case peer.TreeWanted:
		e.requestTree(ev.File)
	}
}

// requestTree hashes the AICH tree of a complete file we share that was
// not hashed when its run started.
func (e *Engine) requestTree(file wire.Hash) {
	r := e.runByHash[file]
	if r == nil || r.transfer == nil || r.tree != nil || r.isTreeHashing || !r.share.Parts.IsFull() {
		return
	}
	r.isTreeHashing = true
	e.disk.send(diskJob{kind: jobHashTree, run: r.id, file: r.handle, block: piece.Block{End: r.file.Size}})
}

func (e *Engine) onHandshake(c *conn, ev peer.HandshakeCompleted) {
	c.handshakenAt = e.now()
	if !e.closeDuplicate(c) {
		return
	}
	caps := c.session.Capabilities()
	user := caps.UserHash
	// A peer's view fills in an unknown address or replaces the gateway's,
	// which a carrier NAT above it hides (matchCarrierNAT). It never
	// replaces what a server or another peer told us, as aMule takes
	// OP_PUBLICIP answers only while it knows no address
	// (BaseClient.cpp:2790-2802): one wrong peer would otherwise flip it.
	_, clientID := e.server.Login()
	isGuess := !e.publicIP.IsValid() || e.publicIP == e.mappedIP
	if isPublicIPv4(ev.YourIP) && wire.IsLowID(clientID) && isGuess {
		e.publicIP = ev.YourIP
	}
	if caps.Port != 0 {
		e.uploadEndpoints[uploadKey{user, c.remote.Addr()}] = uploadTarget{c.endpoint(), wire.CanObfuscate(caps.CryptOptions, user)}
	}
	for _, h := range c.session.Files() {
		if r := e.downloadByHash(h); r != nil && !c.isClosed {
			e.addTransferPeer(c, r)
		}
	}
	if !c.isOutgoing {
		for _, h := range e.matchKnownSource(user, caps) {
			if r := e.runByHash[h]; !c.isClosed && e.isReaskDue(r, user) && !e.isA4AF(user, h) {
				e.addFile(c, r)
			}
		}
	}
	// A peer's Kad port lets Kad bootstrap through it while it knows no
	// node (BaseClient.cpp:846); Kad paces these, the Nodes check only
	// keeps the posts out of its mailbox once it is connected.
	if e.kad != nil && e.kadStatus.Nodes == 0 && caps.KadPort != 0 && c.remote.Addr().Is4() {
		e.kad.Post(kad.Node{Addr: netip.AddrPortFrom(c.remote.Addr(), caps.KadPort), TCPPort: caps.Port, Version: caps.KadVersion})
	}
	if !c.isClosed {
		e.onKadHandshake(c)
		e.onBuddyHandshake(c)
	}
	if !c.isClosed {
		e.runQueueActions(e.queue.OnConnected(c.id, toUploadPeer(c), e.now()))
	}
}

// closeDuplicate closes one of two connections to the same client, by user
// hash and endpoint, and tells whether c stays. Like aMule's
// AttachToAlreadyKnown (ClientList.cpp:372-445) the new one stays: a client
// that comes back, say to give us a slot, may have lost the old one without
// us knowing. When both ends dialled each other at once, each keeping its
// newer connection could close both; so while the older one is younger than
// CONNECTION_TIMEOUT, both ends keep the one the client with the smaller
// user hash opened, aMule's rule for the same race over uTP (UtpDialPolicy.h
// ShouldKeepFoundUtp). A closed c hands its downloads to the one kept. A
// Kad check or the buddy link is tied to its connection; those are left
// alone.
func (e *Engine) closeDuplicate(c *conn) bool {
	user := c.session.Capabilities().UserHash
	var old *conn
	for _, other := range e.conns {
		if other != c && other.isHandshaken() && other.session.Capabilities().UserHash == user && other.endpoint() == c.endpoint() {
			old = other
			break
		}
	}
	if old == nil || old.kadCheck != nil || c.kadCheck != nil || old == e.buddy.conn || c == e.buddy.conn {
		return true
	}
	isOldKept := false
	if old.isOutgoing != c.isOutgoing && e.now().Sub(old.handshakenAt) < connectTimeout {
		isOursKept := bytes.Compare(e.self.UserHash[:], user[:]) < 0
		isOldKept = old.isOutgoing == isOursKept
	}
	if !isOldKept {
		e.closeConn(old, "duplicate")
		return true
	}
	files := c.session.Files()
	e.closeConn(c, "duplicate")
	for _, h := range files {
		if r := e.downloadByHash(h); r != nil && !old.isClosed {
			e.addFile(old, r)
		}
	}
	return false
}

// isReaskDue tells whether a connection the peer opened may carry our file
// request for r. aMule sends it on an incoming connection only when it was
// about to ask that source anyway (BaseClient.cpp:1688-1702); asking again
// within MIN_REQUESTTIME gets us banned as aggressive
// (ClientTCPSocket.cpp:539).
func (e *Engine) isReaskDue(r *run, user wire.Hash) bool {
	asked, ok := r.asked[user]
	return !ok || e.now().Sub(asked) >= fileReaskTime
}

// addTransferPeer tells a download that a handshaken connection serves it.
// A LowID peer that takes direct callbacks gets them at its Kad port on the
// IPv4 address it connected from (BaseClient.cpp:1718).
func (e *Engine) addTransferPeer(c *conn, r *run) {
	caps := c.session.Capabilities()
	user := caps.UserHash
	r.asked[user] = e.now()
	hello := transfer.Source{
		Endpoint:     c.endpoint(),
		ClientID:     caps.ClientID,
		Server:       caps.Server,
		UserHash:     user,
		UDPPort:      caps.UDPPort,
		CanReaskUDP:  caps.UDPVersion > 0 && caps.UDPPort != 0,
		CanExchange:  caps.HasSourceExchange2,
		CanObfuscate: wire.CanObfuscate(caps.CryptOptions, user),
		Software:     caps.Software,
	}
	if caps.ClientID != 0 && caps.HasDirectCallback && caps.KadPort != 0 && c.remote.Addr().Is4() {
		hello.Buddy, hello.IsDirectCallback = netip.AddrPortFrom(c.remote.Addr(), caps.KadPort), true
	}
	e.runTransferActions(r, r.transfer.OnPeerConnected(c.id, hello, e.now()))
}

// addFile makes c serve download r: right away on a handshaken
// connection, or once the handshake completes.
func (e *Engine) addFile(c *conn, r *run) {
	if slices.Contains(c.session.Files(), r.file.Hash) {
		return
	}
	e.runSession(c, c.session.Add(r.file.Hash, r.file.Size, r.share.Parts))
	if c.isHandshaken() && !c.isClosed {
		e.addTransferPeer(c, r)
	}
}

// removeFile stops c serving download h and tells the transfer.
func (e *Engine) removeFile(c *conn, h wire.Hash, reason string) {
	if c.isServer || !slices.Contains(c.session.Files(), h) {
		return
	}
	e.runSession(c, c.session.Remove(h))
	if r := e.downloadByHash(h); r != nil && c.isHandshaken() {
		e.runTransferActions(r, r.transfer.OnPeerGone(c.id, reason, e.now()))
	}
}

// onSlotGranted handles a grant that may arrive before the peer said which
// file it is for: then it is for a download that knows this peer.
func (e *Engine) onSlotGranted(c *conn, file wire.Hash) {
	if file == (wire.Hash{}) {
		caps := c.session.Capabilities()
		for _, h := range e.matchKnownSource(caps.UserHash, caps) {
			if !e.isA4AF(caps.UserHash, h) {
				e.addFile(c, e.runByHash[h])
			}
		}
		files := c.session.Files()
		if len(files) == 0 || c.isClosed {
			return
		}
		file = files[0]
	}
	if r := e.downloadByHash(file); r != nil {
		e.runTransferActions(r, r.transfer.OnSlotGranted(c.id, e.now()))
	}
}

func (e *Engine) onBlocksRequested(c *conn, ev peer.BlocksRequested) {
	r := e.runByHash[ev.File]
	if r == nil || r.transfer == nil {
		return
	}
	for _, block := range ev.Blocks {
		c.uploadBlocks = append(c.uploadBlocks, diskJob{kind: jobRead, run: r.id, file: r.handle, block: block, conn: c.id, hash: ev.File})
	}
	e.sendUploadReads(c)
}

// sendUploadReads reads c's next requested blocks while less than
// uploadBufferSize of its upload data is read and not yet written.
func (e *Engine) sendUploadReads(c *conn) {
	for len(c.uploadBlocks) > 0 && c.uploadBuffered < uploadBufferSize && !c.isClosed {
		job := c.uploadBlocks[0]
		c.uploadBlocks = c.uploadBlocks[1:]
		if e.runByID(job.run) == nil {
			continue
		}
		c.uploadBuffered += job.block.End - job.block.Begin
		e.disk.send(job)
	}
}

// onBlockRead uploads a block read for a connection; from then on its
// packets, not the block, count in uploadBuffered.
func (e *Engine) onBlockRead(d diskDone) {
	c := e.conns[d.job.conn]
	if c == nil {
		return
	}
	c.uploadBuffered -= d.job.block.End - d.job.block.Begin
	r := e.runByID(d.job.run)
	switch {
	case r == nil || r.transfer == nil:
	case d.err != nil:
		r.transfer.OnDiskFailed(disk.IsFull(d.err), d.err.Error())
	case c.session != nil:
		for _, p := range c.session.SendBlock(d.job.hash, d.job.block, d.data).Send {
			payload := toPayload(p)
			c.uploadBuffered += payload
			e.sendPacket(c, p, d.job.hash, payload)
		}
	}
	e.sendUploadReads(c)
}

func toPayload(p wire.Packet) int64 {
	switch p := p.(type) {
	case client.SendingPart:
		return int64(len(p.Data))
	case client.CompressedPart:
		return int64(len(p.Data))
	}
	return 0
}

func toUploadPeer(c *conn) upload.Peer {
	caps := c.session.Capabilities()
	return upload.Peer{
		User:        caps.UserHash,
		IP:          c.remote.Addr(),
		UDPPort:     caps.UDPPort,
		IsLowID:     caps.ClientID != 0,
		MuleVersion: caps.MuleVersion,
	}
}

func (e *Engine) runQueueActions(actions []upload.Action) {
	for _, action := range actions {
		switch a := action.(type) {
		case upload.Grant:
			if c := e.conns[a.Conn]; c != nil && c.session != nil {
				e.runSession(c, c.session.StartUpload())
			}
		case upload.Revoke:
			if c := e.conns[a.Conn]; c != nil && c.session != nil {
				c.uploadBlocks = nil
				e.runSession(c, c.session.StopUpload())
			}
		case upload.SendRank:
			if c := e.conns[a.Conn]; c != nil && c.session != nil {
				e.runSession(c, c.session.SendQueueRank(uint32(a.Rank)))
			}
		case upload.Connect:
			target, ok := e.uploadEndpoints[uploadKey{a.Peer.User, a.Peer.IP}]
			if ok && e.connByEndpoint(target.endpoint) == nil && len(e.conns) < maxConnections {
				e.openPeerConn(target.endpoint, a.Peer.User, target.canObfuscate)
			}
		}
	}
}

// buildPeerSources answers Source Exchange, other than with the peer asking.
// For a download these are its connected sources; a seed, like aMule's
// CKnownFile::CreateSrcInfoPacket (KnownFile.cpp:1038-1110), names the HighID
// peers queued or downloading the file from us that have a part the asker
// lacks.
func (e *Engine) buildPeerSources(file wire.Hash, asking *conn, askerParts piece.Set) []peer.Source {
	r := e.runByHash[file]
	isSeed := r != nil && r.mode == ModeSeed
	var sources []peer.Source
	for _, c := range e.sortedConns() {
		if c == asking || !c.isHandshaken() {
			continue
		}
		caps := c.session.Capabilities()
		if isSeed && (c.uploadFile != file || caps.ClientID != 0 || !matchNeededSource(c.uploadParts, askerParts)) ||
			!isSeed && !slices.Contains(c.session.Files(), file) {
			continue
		}
		src := peer.Source{Port: caps.Port, UserHash: caps.UserHash, IPv6: caps.IPv6, CryptOptions: caps.CryptOptions}
		switch {
		case caps.ClientID == 0 && c.remote.Addr().Is4():
			src.IPv4 = c.remote.Addr()
		case caps.ClientID != 0 && caps.Server.IsValid():
			src.LowID, src.Server = caps.ClientID, caps.Server
		case c.remote.Addr().Is4():
			src.IPv4 = c.remote.Addr()
		}
		sources = append(sources, src)
	}
	return sources
}

// matchNeededSource follows aMule: a source whose parts are unknown is sent
// on hope, one whose parts are known must have a part the asker lacks, or any
// part when the asker did not tell its own.
func matchNeededSource(source, asker piece.Set) bool {
	if source == nil {
		return true
	}
	for i, has := range source {
		if has && (i >= len(asker) || !asker[i]) {
			return true
		}
	}
	return false
}

func toExchangeSources(found []peer.Source) []transfer.Source {
	var sources []transfer.Source
	for _, f := range found {
		src := transfer.Source{UserHash: f.UserHash, CanObfuscate: wire.CanObfuscate(f.CryptOptions, f.UserHash)}
		switch {
		case f.LowID != 0:
			src.ClientID, src.Server = f.LowID, f.Server
		case f.IPv4.IsValid():
			src.Endpoint = netip.AddrPortFrom(f.IPv4, f.Port)
		case f.IPv6.IsValid():
			src.Endpoint = netip.AddrPortFrom(f.IPv6, f.Port)
		}
		sources = append(sources, src)
	}
	return sources
}

func toKadSources(found []kad.Source) []transfer.Source {
	var sources []transfer.Source
	for _, f := range found {
		src := transfer.Source{UserHash: f.UserHash, UDPPort: f.UDPPort, CanObfuscate: wire.CanObfuscate(f.CryptOptions, f.UserHash)}
		switch {
		case f.IsFirewalled():
			src.Buddy, src.BuddyID = f.Buddy, f.BuddyID
		case f.Type == kad.SourceDirectCallback:
			src.Buddy, src.IsDirectCallback = netip.AddrPortFrom(f.Addr.Addr(), f.UDPPort), true
		default:
			src.Endpoint = f.Addr
		}
		sources = append(sources, src)
	}
	return sources
}

// toPacketName is the packet's Go type, which names its opcode, with the
// protocol and opcode bytes for packets no family decodes.
func toPacketName(p wire.Packet) string {
	if u, ok := p.(wire.Unknown); ok {
		return fmt.Sprintf("unknown(%#02x,%#02x)", u.Proto, u.Op)
	}
	return fmt.Sprintf("%T", p)
}
