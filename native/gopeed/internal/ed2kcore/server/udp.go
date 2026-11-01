package server

import (
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	serverwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/server"
)

// eMule's UDP pacing (Opcodes.h, DownloadQueue.cpp, ServerList.cpp).
const (
	udpSearchTime        = 30 * time.Minute             // UDPSERVERREASKTIME, between rounds
	udpSearchSpeed       = time.Second                  // UDPSEARCHSPEED, between packets
	udpStatTime          = 5 * time.Second              // UDPSERVERSTATTIME, between pings
	udpStatReaskTime     = 4*time.Hour + 30*time.Minute // UDPSERVSTATREASKTIME
	maxUDPPacketData     = 510                          // MAX_UDP_PACKET_DATA
	maxRequestsPerServer = 35                           // MAX_REQUESTS_PER_SERVER
	maxFilesPerUDPPacket = 31                           // aMule DownloadQueue.cpp:69, OP_GLOBGETSOURCES
	bytesPerFile         = 20                           // BYTES_PER_FILE_G2
	bytesPerLargeFile    = bytesPerFile + 8             // ADDITIONAL_BYTES_PER_LARGEFILE
	challengeBase        = 0x55AA0000                   // ServerStats challenge prefix
	udpStatMinReaskTime  = 20 * time.Minute             // UDPSERVSTATMINREASKTIME
	cryptPingTimeout     = 20 * time.Second             // ServerList.cpp:310
	cryptPingPortOffset  = 12                           // ServerList.cpp:322
	maxPingPadding       = 16                           // ServerList.cpp:301
)

// udpSearch is the OP_GLOBGETSOURCES(2) series to the server being asked,
// and the status ping cycle.
type udpSearch struct {
	server    *listed
	asked     int
	fileStart int
	lastSent  time.Time

	statCursor int
	lastStat   time.Time
	pings      uint16
}

func (s *Server) onDatagram(from netip.AddrPort, p wire.Packet, now time.Time) []Action {
	var out []Action
	l := s.serverByUDP(from)
	if l == nil {
		return out
	}
	switch p := p.(type) {
	case serverwire.GlobServStatRes:
		if l.challenge == 0 || p.Challenge != l.challenge {
			return out
		}
		l.challenge, l.Failures, l.isDead, l.isCryptPinging = 0, 0, false, false
		l.Ping = uint32(now.Sub(l.PingedAt).Milliseconds())
		l.Users, l.Files, l.SoftFiles, l.UDPFlags = p.Users, p.Files, p.SoftFiles, p.UDPFlags
		l.TCPObfuscationPort, l.UDPObfuscationPort = p.TCPObfuscationPort, p.UDPObfuscationPort
		l.UDPKey, l.UDPKeyIP = p.UDPKey, s.publicIP
	case serverwire.GlobFoundSources:
		for _, f := range p.Files {
			s.addSources(f.Hash, f.Sources, l.Endpoint, true, &out)
		}
	}
	return out
}

// runStats pings one server every UDPSERVERSTATTIME, each at most once per
// UDPSERVSTATREASKTIME. A server still owing the previous answer when its
// turn comes again is dead to UDP.
//
// With our public IP known, a ping is first sent obfuscated; a server
// that leaves it unanswered for 20 s gets a plain one at its next turn,
// and only that one counts as a failure (ServerList.cpp:297-334).
func (s *Server) runStats(now time.Time, out *[]Action) {
	u := &s.udp
	if !u.lastStat.IsZero() && now.Sub(u.lastStat) <= udpStatTime {
		return
	}
	for range s.servers {
		l := s.servers[u.statCursor%len(s.servers)]
		u.statCursor++
		if l.isDead || !l.isResolved() || !s.isPingDue(l, now) {
			continue
		}
		u.lastStat = now
		if !l.isCryptPinging && l.challenge != 0 {
			l.isDead = true
			return
		}
		l.PingedAt = now
		if !l.isCryptPinging && s.publicIP.IsValid() {
			l.isCryptPinging = true
			l.challenge = max(1, s.config.Random.Uint32())
			padding := make([]byte, s.config.Random.IntN(maxPingPadding))
			for i := range padding {
				padding[i] = byte(s.config.Random.Uint32())
			}
			to := netip.AddrPortFrom(l.Endpoint.Addr(), l.Endpoint.Port()+cryptPingPortOffset)
			*out = append(*out, Datagram{To: to, Packet: serverwire.ObfuscatedPing{Challenge: l.challenge, Padding: padding}})
			return
		}
		l.isCryptPinging = false
		u.pings++
		l.challenge = challengeBase + uint32(u.pings)
		l.Failures++
		*out = append(*out, s.buildDatagram(l, serverwire.GlobServStatReq{Challenge: l.challenge}))
		return
	}
}

// isPingDue: an unanswered obfuscated ping is followed by a plain one after
// 20 s; a server whose UDP key belongs to an address we no longer have is
// pinged again once UDPSERVSTATMINREASKTIME has passed
// (ServerList.cpp:1017-1048), else after UDPSERVSTATREASKTIME.
func (s *Server) isPingDue(l *listed, now time.Time) bool {
	since := now.Sub(l.PingedAt)
	switch {
	case l.PingedAt.IsZero():
		return true
	case l.isCryptPinging:
		return since >= cryptPingTimeout
	case l.challenge == 0 && l.UDPKey != 0 && s.publicIP.IsValid() && l.UDPKeyIP != s.publicIP:
		return since >= udpStatMinReaskTime
	}
	return since >= udpStatReaskTime
}

// buildDatagram addresses p to l, obfuscated when l has a UDP key for our
// public IP and takes obfuscated UDP (ServerUDPSocket.cpp:376-384).
func (s *Server) buildDatagram(l *listed, p wire.Packet) Datagram {
	if key := s.udpKey(l); key != 0 {
		return Datagram{To: netip.AddrPortFrom(l.Endpoint.Addr(), l.UDPObfuscationPort), Packet: p, Key: key}
	}
	return Datagram{To: toUDP(l.Endpoint), Packet: p}
}

// udpKey is aMule's GetServerKeyUDP when SupportsObfuscationUDP
// (Server.cpp:303-310); 0 means plain.
func (s *Server) udpKey(l *listed) uint32 {
	if l.UDPFlags&serverwire.UDPFlagUDPObfuscation == 0 || l.UDPObfuscationPort == 0 || !s.publicIP.IsValid() || l.UDPKeyIP != s.publicIP {
		return 0
	}
	return l.UDPKey
}

// UDPKeyByAddr is the key that opens an obfuscated datagram from a
// server's UDP endpoint: the challenge while an obfuscated ping awaits its
// answer, else the server's UDP key; 0 when none is expected
// (ServerUDPSocket.cpp:63-90).
func (s *Server) UDPKeyByAddr(from netip.AddrPort) uint32 {
	l := s.serverByUDP(from)
	switch {
	case l == nil:
		return 0
	case l.isCryptPinging:
		return l.challenge
	}
	return s.udpKey(l)
}

// runSearch sends at most one OP_GLOBGETSOURCES2, or OP_GLOBGETSOURCES to
// a server without it (aMule DownloadQueue.cpp:924-955), per
// UDPSEARCHSPEED. A
// server is asked again only UDPSERVERREASKTIME after its last series, so
// none is asked more often than in eMule's rounds, but a server whose
// support shows up late is asked at once instead of a round later. Each
// series asks at most MAX_REQUESTS_PER_SERVER files; past that the file
// list rotates so the next server is asked about the others.
func (s *Server) runSearch(now time.Time, out *[]Action) {
	u := &s.udp
	if !u.lastSent.IsZero() && now.Sub(u.lastSent) < udpSearchSpeed {
		return
	}
	if u.server == nil || u.server == s.current {
		u.server, u.asked = s.nextSearchServer(now), 0
		if u.server == nil {
			return
		}
	}
	files := s.searchFiles(u.server.UDPFlags)
	quota := min(len(files), maxRequestsPerServer)
	var request wire.Packet
	before := u.asked
	if u.server.UDPFlags&serverwire.UDPFlagGetSources2 != 0 {
		var batch []serverwire.GetSources
		for size := 0; u.asked < quota && size < maxUDPPacketData; u.asked++ {
			w := files[u.asked]
			batch = append(batch, serverwire.GetSources{Hash: w.File, Size: w.Size})
			size += bytesPerFile
			if w.Size > largeFileSize {
				size += bytesPerLargeFile - bytesPerFile
			}
		}
		request = serverwire.GlobGetSources2{Files: batch}
	} else {
		var batch []wire.Hash
		for ; u.asked < quota && len(batch) < maxFilesPerUDPPacket; u.asked++ {
			batch = append(batch, files[u.asked].File)
		}
		request = serverwire.GlobGetSources{Files: batch}
	}
	if u.asked > before {
		*out = append(*out, s.buildDatagram(u.server, request))
		u.lastSent = now
	}
	if u.asked >= quota {
		if u.asked == maxRequestsPerServer {
			u.fileStart += maxRequestsPerServer
		}
		u.server.searchedAt = now
		u.server = nil
	}
}

// searchFiles is the incomplete files a server with udpFlags can be asked
// about, starting at the rotation point; a large file only of a server
// that announces large-file support (aMule DownloadQueue.cpp:928). A
// server is asked only once its flags say it takes global source
// requests. aMule also asks servers whose flags are unknown, one file per
// packet; Kelpie waits for the status answer, which comes within minutes.
func (s *Server) searchFiles(udpFlags uint32) []Wanted {
	if udpFlags&(serverwire.UDPFlagGetSources|serverwire.UDPFlagGetSources2) == 0 {
		return nil
	}
	var files []Wanted
	n := len(s.wanted)
	for i := range n {
		w := s.wanted[(s.udp.fileStart+i)%n]
		if !w.IsComplete && w.Sources < maxSourcesUDP && (w.Size <= largeFileSize || udpFlags&serverwire.UDPFlagLargeFiles != 0) {
			files = append(files, w)
		}
	}
	return files
}

// nextSearchServer is the first server in list order that is due, skipping
// the connected server, which is asked over TCP. A server that failed over
// TCP may still answer over UDP, as aMule assumes.
func (s *Server) nextSearchServer(now time.Time) *listed {
	for _, l := range s.servers {
		isDue := l.searchedAt.IsZero() || now.Sub(l.searchedAt) > udpSearchTime
		if l != s.current && isDue && l.isResolved() && len(s.searchFiles(l.UDPFlags)) > 0 {
			return l
		}
	}
	return nil
}

// serverByUDP matches a server's UDP port, its UDP obfuscation port, and
// the port of obfuscated pings (ServerList.cpp:648-659).
func (s *Server) serverByUDP(from netip.AddrPort) *listed {
	for _, l := range s.servers {
		port := l.Endpoint.Port()
		if l.Endpoint.Addr() == from.Addr() && (from.Port() == port+4 || from.Port() == port+cryptPingPortOffset ||
			(l.UDPObfuscationPort != 0 && from.Port() == l.UDPObfuscationPort)) {
			return l
		}
	}
	return nil
}

// toUDP gives a server's UDP endpoint: its TCP port plus 4.
func toUDP(endpoint netip.AddrPort) netip.AddrPort {
	return netip.AddrPortFrom(endpoint.Addr(), endpoint.Port()+4)
}
