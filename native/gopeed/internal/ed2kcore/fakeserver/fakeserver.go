// Package fakeserver is a small in-memory eD2k server for tests. It runs on
// any transport.Transport, usually a host of the fake network, and speaks the
// server side of login, file offers, source queries over TCP and UDP, and
// callback relay. It keeps no state across Run and does no searches.
package fakeserver

import (
	"context"
	"crypto/md5"
	"encoding/binary"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/clock"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transport"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	serverwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/server"
)

const (
	// connectBackTimeout bounds the HighID test; on the fake network a LowID
	// host refuses at once, so only a real transport ever waits for it.
	connectBackTimeout = 5 * time.Second
	maxSourcesPerFile  = 255
	fileLimit          = 100000

	tcpFlags = serverwire.FlagCompression | serverwire.FlagNewTags | serverwire.FlagUnicode | serverwire.FlagLargeFiles
	udpFlags = serverwire.UDPFlagGetSources | serverwire.UDPFlagGetSources2 | serverwire.UDPFlagNewTags |
		serverwire.UDPFlagUnicode | serverwire.UDPFlagLargeFiles

	metUDPFlags           byte = 0x92 // ST_UDPFLAGS
	metTCPPortObfuscation byte = 0x97 // ST_TCPPORTOBFUSCATION

	// udpObfuscationOffset is where eD2k servers take obfuscated pings
	// (aMule ServerList.cpp:322); this one takes all obfuscated UDP there.
	udpObfuscationOffset = 12
)

type Config struct {
	Transport transport.Transport
	Clock     clock.Clock
	// Addr is the address clients reach the server at. Its port is the TCP
	// port; UDP listens on the port plus 4, as eD2k servers do. Port 0
	// picks a free TCP port.
	Addr netip.AddrPort
	Name string

	// ShouldDropLogins makes the server leave every login unanswered.
	ShouldDropLogins bool
	// Delay holds back every answer, TCP and UDP, by this long on Clock.
	Delay time.Duration
	// ObfuscationPort, when not 0, is a second TCP port where clients log
	// in obfuscated; the server announces it.
	ObfuscationPort uint16
	// UDPKey, when not 0, makes the server take obfuscated UDP on its port
	// plus 12, obfuscated pings included, and announce it. A real server
	// derives each client's key from the client's address; this one gives
	// UDPKey XOR the client ID.
	UDPKey uint32
	// UDPMarker, when not 0, is the first byte of every obfuscated answer.
	// A real server picks it at random, any byte but 0xE3, so it may be a
	// Kad protocol byte.
	UDPMarker byte
}

type Server struct {
	config     Config
	listener   transport.Listener
	obfuscated transport.Listener
	udp        transport.PacketConn
	// obfuscatedUDP is the UDP port plus 12, open with Config.UDPKey.
	obfuscatedUDP transport.PacketConn

	// mu guards the clients and their files: each connection runs on its
	// own goroutine and reads the others' for sources and callbacks.
	mu        sync.Mutex
	clients   map[*client]struct{}
	nextLowID uint32
}

// client is one logged-in connection.
type client struct {
	conn net.Conn
	addr netip.Addr
	id   uint32
	port uint16
	user wire.Hash
	// cryptOptions are the login's crypt capabilities in the CryptOptions
	// layout: supported, requested, required in bits 0-2.
	cryptOptions byte
	files        map[wire.Hash]struct{}

	// writeMu keeps packets whole: another client's goroutine writes a
	// callback request to this connection while its own writes answers.
	writeMu sync.Mutex
}

// Create opens the TCP listener and UDP socket, so clients can dial Addr as
// soon as it returns; Run serves them.
func Create(config Config) (*Server, error) {
	listener, err := config.Transport.OpenListener(int(config.Addr.Port()))
	if err != nil {
		return nil, err
	}
	s := &Server{config: config, listener: listener, clients: map[*client]struct{}{}, nextLowID: 1}
	s.config.Addr = netip.AddrPortFrom(config.Addr.Addr(), uint16(listener.Port()))
	s.udp, err = config.Transport.OpenUDP(listener.Port() + 4)
	if err == nil && config.ObfuscationPort != 0 {
		s.obfuscated, err = config.Transport.OpenListener(int(config.ObfuscationPort))
	}
	if err == nil && config.UDPKey != 0 {
		s.obfuscatedUDP, err = config.Transport.OpenUDP(listener.Port() + udpObfuscationOffset)
	}
	if err != nil {
		s.close()
		return nil, err
	}
	return s, nil
}

// close closes every socket that is open.
func (s *Server) close() {
	s.listener.Close()
	if s.udp != nil {
		s.udp.Close()
	}
	if s.obfuscated != nil {
		s.obfuscated.Close()
	}
	if s.obfuscatedUDP != nil {
		s.obfuscatedUDP.Close()
	}
}

func (s *Server) Addr() netip.AddrPort { return s.config.Addr }

// Run serves clients until ctx ends, then closes every socket.
func (s *Server) Run(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		s.runUDP(ctx, s.udp, false)
	}()
	if s.obfuscatedUDP != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.runUDP(ctx, s.obfuscatedUDP, true)
		}()
	}
	errs := make(chan error, 2)
	accept := func(listener transport.Listener, isObfuscated bool) {
		defer wg.Done()
		for {
			conn, _, err := listener.Accept()
			if err != nil {
				errs <- err
				return
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				if !isObfuscated {
					s.runConn(ctx, conn)
					return
				}
				obfuscated, err := openObfuscated(conn)
				if err != nil {
					conn.Close()
					return
				}
				s.runConn(ctx, obfuscated)
			}()
		}
	}
	go accept(s.listener, false)
	if s.obfuscated != nil {
		wg.Add(1)
		go accept(s.obfuscated, true)
	}
	var err error
	select {
	case <-ctx.Done():
	case err = <-errs:
	}
	cancel()
	s.close()
	wg.Wait()
	return err
}

// runConn serves one connection: a login first, then requests.
func (s *Server) runConn(ctx context.Context, conn net.Conn) {
	go func() {
		<-ctx.Done()
		conn.Close()
	}()
	defer conn.Close()
	var c *client
	defer func() {
		if c != nil {
			s.mu.Lock()
			delete(s.clients, c)
			s.mu.Unlock()
		}
	}()
	for {
		frame, err := wire.ParseFrameFrom(conn)
		if err != nil {
			return
		}
		p, err := serverwire.Parse(frame.Protocol, frame.Opcode, frame.Body)
		if err != nil {
			return
		}
		if !s.runDelay(ctx) {
			return
		}
		if c == nil {
			if login, ok := p.(serverwire.Login); ok && !s.config.ShouldDropLogins {
				c = s.onLogin(ctx, conn, login)
			}
			continue
		}
		switch p := p.(type) {
		case serverwire.OfferFiles:
			s.onOfferFiles(c, p)
		case serverwire.GetSources:
			c.send(serverwire.FoundSources{Hash: p.Hash, Sources: s.sourcesByFile(p.Hash, c), IsObfu: p.IsObfu})
		case serverwire.CallbackRequest:
			s.onCallbackRequest(c, p)
		}
	}
}

func (s *Server) onLogin(ctx context.Context, conn net.Conn, login serverwire.Login) *client {
	addr := conn.RemoteAddr().(*net.TCPAddr).AddrPort().Addr().Unmap()
	c := &client{
		conn:         conn,
		addr:         addr,
		port:         login.Port,
		user:         login.UserHash,
		cryptOptions: byte(login.Flags>>9) & 0x07,
		files:        map[wire.Hash]struct{}{},
	}
	if addr.Is4() && s.probeHighID(ctx, netip.AddrPortFrom(addr, login.Port)) {
		c.id = wire.ToClientID(addr)
	}
	s.mu.Lock()
	if c.id == 0 {
		c.id = s.nextLowID
		s.nextLowID++
	}
	s.clients[c] = struct{}{}
	s.mu.Unlock()
	var reported netip.Addr
	if addr.Is4() {
		reported = addr
	}
	idChange := serverwire.IDChange{ClientID: c.id, Flags: tcpFlags, ReportedIP: reported}
	if s.config.ObfuscationPort != 0 {
		idChange.Flags |= serverwire.FlagTCPObfuscation
		idChange.ObfuscationPort = uint32(s.config.ObfuscationPort)
	}
	c.send(idChange)
	c.send(s.status())
	c.send(serverwire.ServerIdent{Hash: md5.Sum([]byte(s.config.Addr.String())), Addr: s.config.Addr, Name: s.config.Name})
	return c
}

// probeHighID connects back to the client's port, as real servers do.
func (s *Server) probeHighID(ctx context.Context, addr netip.AddrPort) bool {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	timer := s.config.Clock.CreateTimer(connectBackTimeout)
	defer timer.Stop()
	go func() {
		select {
		case <-timer.C():
			cancel()
		case <-ctx.Done():
		}
	}()
	conn, err := s.config.Transport.OpenTCP(ctx, addr)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// onOfferFiles adds to what c shares; complete and partial files alike are
// sources. An empty offer is the client's keep-alive.
func (s *Server) onOfferFiles(c *client, p serverwire.OfferFiles) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, f := range p.Files {
		c.files[f.Hash] = struct{}{}
	}
}

func (s *Server) onCallbackRequest(c *client, p serverwire.CallbackRequest) {
	if wire.IsLowID(c.id) {
		return
	}
	s.mu.Lock()
	var target *client
	for other := range s.clients {
		if other.id == p.ClientID {
			target = other
		}
	}
	s.mu.Unlock()
	if target == nil {
		c.send(serverwire.CallbackFailed{})
		return
	}
	target.send(serverwire.CallbackRequested{Addr: netip.AddrPortFrom(c.addr, c.port), CryptOptions: c.cryptOptions, UserHash: c.user})
}

// sourcesByFile is every client other than except sharing file, at most
// 255, the count a source answer can carry.
func (s *Server) sourcesByFile(file wire.Hash, except *client) []serverwire.Source {
	s.mu.Lock()
	defer s.mu.Unlock()
	var sources []serverwire.Source
	for c := range s.clients {
		if _, ok := c.files[file]; ok && c != except && len(sources) < maxSourcesPerFile {
			sources = append(sources, serverwire.Source{ClientID: c.id, Port: c.port})
		}
	}
	return sources
}

func (s *Server) status() serverwire.ServerStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	status := serverwire.ServerStatus{Users: uint32(len(s.clients))}
	for c := range s.clients {
		status.Files += uint32(len(c.files))
	}
	return status
}

// runUDP serves one UDP socket. On the obfuscated one a datagram is either
// encrypted with the client's key, and so is the answer, or a bare
// challenge, an obfuscated ping, answered encrypted with the challenge.
func (s *Server) runUDP(ctx context.Context, conn transport.PacketConn, isObfuscated bool) {
	buf := make([]byte, 64<<10)
	for {
		n, from, err := conn.ReadFrom(buf)
		if err != nil {
			return
		}
		data, key := buf[:n], uint32(0)
		if isObfuscated {
			key = s.udpKeyByAddr(from.Addr())
			if plain, ok := openDatagram(data, key); ok {
				data = plain
			} else if n >= 4 {
				key = binary.LittleEndian.Uint32(data)
				data = serverwire.GlobServStatReq{Challenge: key}.Build(nil)
			} else {
				continue
			}
		}
		reply := s.buildUDPAnswer(data, from.Addr())
		if reply == nil {
			continue
		}
		if !s.runDelay(ctx) {
			return
		}
		answer := reply.Build(nil)
		if key != 0 {
			answer = sealDatagram(answer, key, s.config.UDPMarker)
		}
		conn.WriteTo(answer, from)
	}
}

func (s *Server) buildUDPAnswer(data []byte, from netip.Addr) wire.Packet {
	frame, err := wire.ParseDatagram(data)
	if err != nil {
		return nil
	}
	p, err := serverwire.ParseUDP(frame.Protocol, frame.Opcode, frame.Body)
	if err != nil {
		return nil
	}
	switch p := p.(type) {
	case serverwire.GlobGetSources:
		return s.buildFound(p.Files)
	case serverwire.GlobGetSources2:
		var files []wire.Hash
		for _, f := range p.Files {
			files = append(files, f.Hash)
		}
		return s.buildFound(files)
	case serverwire.GlobServStatReq:
		status := s.status()
		res := serverwire.GlobServStatRes{
			Challenge: p.Challenge, Users: status.Users, Files: status.Files,
			MaxUsers: status.Users + 1000, SoftFiles: fileLimit, HardFiles: fileLimit, UDPFlags: s.udpFlags(),
			TCPObfuscationPort: s.config.ObfuscationPort,
		}
		if s.config.UDPKey != 0 {
			res.UDPObfuscationPort, res.UDPKey = s.config.Addr.Port()+udpObfuscationOffset, s.udpKeyByAddr(from)
		}
		return res
	}
	return nil
}

func (s *Server) udpKeyByAddr(ip netip.Addr) uint32 {
	return s.config.UDPKey ^ wire.ToClientID(ip)
}

// buildFound answers a global source query; nil when no file has sources.
func (s *Server) buildFound(files []wire.Hash) wire.Packet {
	var found serverwire.GlobFoundSources
	for _, f := range files {
		if sources := s.sourcesByFile(f, nil); len(sources) > 0 {
			found.Files = append(found.Files, serverwire.FoundSources{Hash: f, Sources: sources})
		}
	}
	if len(found.Files) == 0 {
		return nil
	}
	return found
}

// runDelay waits out Config.Delay; it reports false when ctx ended first.
func (s *Server) runDelay(ctx context.Context) bool {
	if s.config.Delay <= 0 {
		return true
	}
	timer := s.config.Clock.CreateTimer(s.config.Delay)
	defer timer.Stop()
	select {
	case <-timer.C():
		return true
	case <-ctx.Done():
		return false
	}
}

// send writes one packet; a failed write shows up as a read error on the
// connection's own loop, which then drops the client.
func (c *client) send(p wire.Packet) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	c.conn.Write(wire.BuildPacket(nil, p))
}

func (s *Server) udpFlags() uint32 {
	flags := udpFlags
	if s.config.ObfuscationPort != 0 {
		flags |= serverwire.UDPFlagTCPObfuscation
	}
	if s.config.UDPKey != 0 {
		flags |= serverwire.UDPFlagUDPObfuscation
	}
	return flags
}

// BuildMet builds a server.met listing servers, each announcing its UDP
// flags, so clients ask it for global sources, and its obfuscation port.
func BuildMet(servers ...*Server) []byte {
	b := binary.LittleEndian.AppendUint32([]byte{0x0E}, uint32(len(servers)))
	for _, s := range servers {
		b = wire.BuildAddrPort(b, s.config.Addr)
		tags := []wire.Tag{
			{Type: wire.TagString, ID: 0x01, String: "fakeserver " + s.config.Addr.String()},
			{Type: wire.TagUint32, ID: metUDPFlags, Uint: uint64(s.udpFlags())},
		}
		if s.config.ObfuscationPort != 0 {
			tags = append(tags, wire.Tag{Type: wire.TagUint16, ID: metTCPPortObfuscation, Uint: uint64(s.config.ObfuscationPort)})
		}
		b = wire.BuildTags(b, tags)
	}
	return b
}
