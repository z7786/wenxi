// Package kad is the Kad actor (ADR-0005): it owns the routing table, the
// UDP socket and Kad's timers, finds sources for the files the engine wants
// and publishes us as a source. Kad is IPv4 only.
//
// eMule serves Kad and eD2k UDP (reasks, server UDP) on one port, so Kad
// owns that socket for both. Datagrams whose first byte is not a Kad
// protocol byte (0xE4, 0xE5) go to the engine as Events; the engine posts
// its own datagrams. Kad datagrams may be obfuscated
// (obfuscation.ParseKadDatagram); a datagram Kad cannot read either way,
// such as an obfuscated eD2k one, is forwarded unchanged. Servers start
// obfuscated datagrams with any byte but 0xE3 (aMule
// EncryptedDatagramSocket.cpp:451), so about 1 in 128 of them looks like
// Kad and is lost here; aMule keeps server UDP on a socket of its own.
//
// Post and Events are safe to use from another goroutine and never block,
// as a hub's sends to the other hub must (ADR-0005): posted messages share
// one mailbox and events one outbox, both dropping when full, except that
// Wanted and Buddy hold only the latest value, a Status is sent again until
// it gets through, and a dropped State is replaced on the next tick.
package kad

import (
	"context"
	crand "crypto/rand"
	"encoding/binary"
	"math/rand/v2"
	"net/netip"
	"sync"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/clock"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/obfuscation"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transport"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
)

const (
	tickInterval = time.Second // SEARCH_JUMPSTART
	queueSize    = 256
	maxDatagram  = 65536
)

type Config struct {
	Transport transport.Transport
	Clock     clock.Clock
	// Port is the UDP port shared by Kad and eD2k UDP; 0 picks one.
	Port     int
	TCPPort  uint16
	UserHash wire.Hash
	// State is the persisted Kad state; a zero ID makes a new one.
	State store.Kad
	// Nodes are bootstrap contacts, as ParseNodes reads them.
	Nodes []Node
	// Rand drives random lookup targets; nil seeds one from crypto/rand.
	Rand *rand.Rand
}

// Datagram is a non-Kad UDP datagram: received from Addr, or to send to
// Addr.
type Datagram struct {
	Addr netip.AddrPort
	Data []byte
}

// Message is what the engine posts to Kad: Wanted, Buddy, a Datagram to
// send, Callback, FirewallAckReceived, FirewallAck, FirewallUDP,
// UDPCheckEnded, and the Node an eD2k peer's hello named, which Kad may
// bootstrap from.
type Message interface{ isMessage() }

// Event is what Kad tells the engine: SourcesFound, the non-Kad Datagrams
// it received, Status, State, and what Kad needs a TCP connection for,
// which only the engine has: FirewallCheck, UDPCheck, BuddyFound,
// BuddyRequested and CallbackRequested.
type Event interface{ isEvent() }

// State is the Kad part of the Durable State: first as BuildKad made it,
// then each tick. Run returns the last one.
type State store.Kad

func (Datagram) isMessage() {}
func (Node) isMessage()     {}
func (Datagram) isEvent()   {}
func (State) isEvent()      {}

type Kad struct {
	cfg     Config
	wanted  chan Wanted
	buddies chan Buddy
	inbox   chan Message
	events  chan Event
}

func BuildKad(cfg Config) *Kad {
	if cfg.State.ID == (wire.Hash{}) {
		crand.Read(cfg.State.ID[:])
	}
	for cfg.State.UDPKey == 0 {
		var key [4]byte
		crand.Read(key[:])
		cfg.State.UDPKey = binary.LittleEndian.Uint32(key[:])
	}
	if cfg.Rand == nil {
		var seed [32]byte
		crand.Read(seed[:])
		cfg.Rand = rand.New(rand.NewChaCha8(seed))
	}
	k := &Kad{
		cfg:     cfg,
		wanted:  make(chan Wanted, 1),
		buddies: make(chan Buddy, 1),
		inbox:   make(chan Message, queueSize),
		events:  make(chan Event, queueSize),
	}
	k.events <- State{ID: cfg.State.ID, IsFirewalled: true, UDPKey: cfg.State.UDPKey, Nodes: cfg.State.Nodes}
	return k
}

// ID is our Kad ID, fixed from BuildKad on.
func (k *Kad) ID() wire.Hash { return k.cfg.State.ID }

// Post hands Kad a message from the engine.
func (k *Kad) Post(m Message) {
	switch m := m.(type) {
	case Wanted:
		setLatest(k.wanted, m)
	case Buddy:
		setLatest(k.buddies, m)
	default:
		sendOrDrop(k.inbox, m)
	}
}

func (k *Kad) Events() <-chan Event { return k.events }

// Run serves Kad until ctx ends and returns the last State. It fails only
// if the UDP socket cannot be opened.
func (k *Kad) Run(ctx context.Context) (State, error) {
	conn, err := k.cfg.Transport.OpenUDP(k.cfg.Port)
	if err != nil {
		return State{}, err
	}
	ctx, cancel := context.WithCancel(ctx)
	reads := make(chan Datagram)
	var reader sync.WaitGroup
	reader.Add(1)
	go func() {
		defer reader.Done()
		runReader(ctx, conn, reads)
	}()
	defer func() {
		cancel()
		conn.Close()
		reader.Wait()
	}()

	now := k.cfg.Clock.Now()
	c := buildCore(coreConfig{
		ID: k.cfg.State.ID, UserHash: k.cfg.UserHash, TCPPort: k.cfg.TCPPort,
		UDPPort: uint16(conn.Port()), UDPKey: k.cfg.State.UDPKey, Rand: k.cfg.Rand,
	}, now)
	var nodes []Node
	for _, n := range k.cfg.State.Nodes {
		nodes = append(nodes, Node{ID: n.ID, Addr: n.Addr, TCPPort: n.TCPPort, Version: n.Version})
	}
	c.addNodes(append(nodes, k.cfg.Nodes...), now)
	ticker := k.cfg.Clock.CreateTicker(tickInterval)
	defer ticker.Stop()

	var reported Status
	isReported := false
	for {
		if status := c.status(); (!isReported || status != reported) && sendOrDrop(k.events, Event(status)) {
			reported, isReported = status, true
		}
		var out output
		select {
		case <-ctx.Done():
			return c.state(), nil
		case d := <-reads:
			if p, keys, isKad := c.parseDatagram(d); isKad {
				if p != nil {
					out = c.onPacket(d.Addr, p, keys, k.cfg.Clock.Now())
				}
			} else {
				sendOrDrop(k.events, Event(d))
			}
		case <-ticker.C():
			out = c.onTick(k.cfg.Clock.Now())
			sendOrDrop(k.events, Event(c.state()))
		case w := <-k.wanted:
			c.setWanted(w, k.cfg.Clock.Now())
		case b := <-k.buddies:
			c.setBuddy(b)
		case m := <-k.inbox:
			if d, ok := m.(Datagram); ok {
				conn.WriteTo(d.Data, d.Addr)
			} else {
				out = c.onMessage(m, k.cfg.Clock.Now())
			}
		}
		for _, d := range out.datagrams {
			conn.WriteTo(c.buildDatagram(d), d.to)
		}
		for _, f := range out.found {
			sendOrDrop(k.events, Event(f))
		}
		for _, r := range out.requests {
			sendOrDrop(k.events, r)
		}
	}
}

func runReader(ctx context.Context, conn transport.PacketConn, reads chan<- Datagram) {
	buf := make([]byte, maxDatagram)
	for {
		n, from, err := conn.ReadFrom(buf)
		if err != nil {
			return
		}
		select {
		case reads <- Datagram{Addr: from, Data: append([]byte(nil), buf[:n]...)}:
		case <-ctx.Done():
			return
		}
	}
}

// setLatest replaces the value waiting in a latest-value slot.
func setLatest[T any](slot chan T, v T) {
	for {
		select {
		case slot <- v:
			return
		default:
		}
		select {
		case <-slot:
		default:
		}
	}
}

func sendOrDrop[T any](queue chan T, v T) bool {
	select {
	case queue <- v:
		return true
	default:
		return false
	}
}

func (c *core) state() State {
	state := State{ID: c.id, IsFirewalled: c.firewall.isFirewalled(), UDPKey: c.udpKey}
	for _, n := range c.table.nodes() {
		state.Nodes = append(state.Nodes, toStoreNode(n))
	}
	return state
}

// buildDatagram is a datagram's wire form, obfuscated as d asks.
func (c *core) buildDatagram(d datagram) []byte {
	data := d.packet.Build(nil)
	if d.nodeID == (wire.Hash{}) && d.receiverKey == 0 {
		return data
	}
	var nodeID []byte
	if d.nodeID != (wire.Hash{}) {
		nodeID = kadwire.BuildID(nil, d.nodeID)
	}
	return obfuscation.BuildKadDatagram(obfuscation.KadDatagram{Packet: data, ReceiverKey: d.receiverKey, SenderKey: d.senderKey}, nodeID, c.rng.Uint32())
}

// parseDatagram reads a plain or obfuscated Kad datagram. isKad is false
// for datagrams that belong to the engine; p is nil for a Kad datagram that
// does not decode.
func (c *core) parseDatagram(d Datagram) (p wire.Packet, k keys, isKad bool) {
	data := d.Data
	if !kadwire.IsDatagram(data) {
		kd, ok := obfuscation.ParseKadDatagram(data, kadwire.BuildID(nil, c.id), obfuscation.BuildKadVerifyKey(c.udpKey, d.Addr.Addr()))
		if !ok || !kadwire.IsDatagram(kd.Packet) {
			return nil, keys{}, false
		}
		data, k = kd.Packet, keys{sender: kd.SenderKey, receiver: kd.ReceiverKey}
	}
	p, ok := parsePacket(data)
	if !ok {
		return nil, keys{}, true
	}
	return p, k, true
}

// parsePacket decodes a Kad datagram, inflating 0xE5 packets.
func parsePacket(data []byte) (wire.Packet, bool) {
	frame, err := wire.ParseDatagram(data)
	if err != nil {
		return nil, false
	}
	p, err := kadwire.Parse(frame.Protocol, frame.Opcode, frame.Body)
	return p, err == nil
}
