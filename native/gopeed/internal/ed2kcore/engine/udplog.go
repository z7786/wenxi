package engine

import (
	"fmt"
	"log"
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/clock"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transport"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
	serverwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/server"
)

// kadLogTime spaces the Kad datagram counts; a line per Kad datagram would
// bury the server and peer lines.
const kadLogTime = time.Minute

// buildUDPTransport is what UDP sockets open through, whichever actor owns
// them: the engine, or Kad. With a packet log, it logs every datagram;
// isServer marks the server socket.
func (e *Engine) buildUDPTransport(isServer bool) transport.Transport {
	if e.packetLog == nil {
		return e.transport
	}
	return udpLogTransport{Transport: e.transport, log: e.packetLog, clock: e.ports.Clock, isServer: isServer}
}

type udpLogTransport struct {
	transport.Transport
	log      *log.Logger
	clock    clock.Clock
	isServer bool
}

func (t udpLogTransport) OpenUDP(port int) (transport.PacketConn, error) {
	conn, err := t.Transport.OpenUDP(port)
	if err != nil {
		return nil, err
	}
	now := t.clock.Now()
	return &udpLogConn{PacketConn: conn, log: t.log, clock: t.clock, kadIn: kadCount{since: now}, kadOut: kadCount{since: now}, isServer: t.isServer}, nil
}

// udpLogConn counts Kad datagrams per direction: only the socket's reader
// leaf reads and only its owning hub writes, so neither count is shared.
// On the server socket, isServer, a datagram is obfuscated unless it starts
// with 0xE3, so it is named by that rule and never counted as Kad.
type udpLogConn struct {
	transport.PacketConn
	log           *log.Logger
	clock         clock.Clock
	kadIn, kadOut kadCount
	isServer      bool
}

type kadCount struct {
	datagrams, bytes int
	since            time.Time
}

func (c *udpLogConn) ReadFrom(b []byte) (int, netip.AddrPort, error) {
	n, from, err := c.PacketConn.ReadFrom(b)
	if err == nil {
		c.send(&c.kadIn, "in ", from, b[:n])
	}
	return n, from, err
}

func (c *udpLogConn) WriteTo(b []byte, addr netip.AddrPort) (int, error) {
	n, err := c.PacketConn.WriteTo(b, addr)
	if err == nil {
		c.send(&c.kadOut, "out", addr, b)
	}
	return n, err
}

func (c *udpLogConn) send(kad *kadCount, direction string, addr netip.AddrPort, data []byte) {
	switch {
	case c.isServer && len(data) > 0 && data[0] != wire.ProtocolEDonkey:
		c.log.Printf("udp %s %s obfuscated %d", direction, addr, len(data))
		return
	case c.isServer || !kadwire.IsDatagram(data):
		c.log.Printf("udp %s %s %s %d", direction, addr, toDatagramName(data), len(data))
		return
	}
	kad.datagrams, kad.bytes = kad.datagrams+1, kad.bytes+len(data)
	now := c.clock.Now()
	if now.Sub(kad.since) < kadLogTime {
		return
	}
	c.log.Printf("udp kad %s %d (%d B) in %s", direction, kad.datagrams, kad.bytes, now.Sub(kad.since).Round(time.Second))
	*kad = kadCount{since: now}
}

// toDatagramName names an eD2k datagram like toPacketName, adding the
// source count of server answers, which is what the log is read for.
func toDatagramName(data []byte) string {
	if len(data) > 0 && data[0] != wire.ProtocolEDonkey && data[0] != wire.ProtocolEMule && data[0] != wire.ProtocolPacked {
		return "obfuscated"
	}
	frame, err := wire.ParseDatagram(data)
	if err != nil {
		return "unparsed"
	}
	parse := serverwire.ParseUDP
	if frame.Protocol == wire.ProtocolEMule {
		parse = client.ParseUDP
	}
	p, err := parse(frame.Protocol, frame.Opcode, frame.Body)
	if err != nil {
		return fmt.Sprintf("broken(%#02x,%#02x)", frame.Protocol, frame.Opcode)
	}
	switch p := p.(type) {
	case serverwire.GlobFoundSources:
		count := 0
		for _, f := range p.Files {
			count += len(f.Sources)
		}
		return fmt.Sprintf("%s files=%d sources=%d", toPacketName(p), len(p.Files), count)
	case serverwire.GlobGetSources2:
		return fmt.Sprintf("%s files=%d", toPacketName(p), len(p.Files))
	case serverwire.GlobServStatRes:
		return fmt.Sprintf("%s users=%d files=%d udpFlags=%#x", toPacketName(p), p.Users, p.Files, p.UDPFlags)
	}
	return toPacketName(p)
}
