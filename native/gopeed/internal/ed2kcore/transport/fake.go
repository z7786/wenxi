package transport

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"syscall"
)

const (
	firstEphemeralPort = 49152
	acceptBacklog      = 128
	udpQueueSize       = 1024
)

// Network is an in-memory internet. Hosts added to it dial, listen and send
// datagrams to each other by address.
type Network struct {
	// mu guards every host: the leaves of all engines under test dial and
	// send through them at once.
	mu    sync.Mutex
	hosts map[netip.Addr]*Host
	names map[string]netip.Addr
}

func BuildNetwork() *Network {
	return &Network{hosts: map[netip.Addr]*Host{}, names: map[string]netip.Addr{}}
}

// SetName makes LookupHost resolve name to addr on every host.
func (n *Network) SetName(name string, addr netip.Addr) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.names[name] = addr
}

// AddHost adds a host owning addrs, IPv4 and/or IPv6. It can reach only
// addresses of a family it owns.
func (n *Network) AddHost(addrs ...netip.Addr) *Host {
	n.mu.Lock()
	defer n.mu.Unlock()
	h := &Host{
		network:   n,
		listeners: map[int]*fakeListener{},
		sockets:   map[int]*fakePacketConn{},
		conns:     map[*pipeConn]struct{}{},
		udpPeers:  map[netip.Addr]bool{},
		nextPort:  firstEphemeralPort,
	}
	for _, addr := range addrs {
		addr = addr.Unmap()
		if _, ok := n.hosts[addr]; ok {
			panic(fmt.Sprintf("transport: address %v already in use", addr))
		}
		n.hosts[addr] = h
		h.addrs = append(h.addrs, addr)
	}
	return h
}

// Host is one machine on a Network; it implements Transport. All of its state
// is guarded by its Network's mutex.
type Host struct {
	network       *Network
	addrs         []netip.Addr
	listeners     map[int]*fakeListener
	sockets       map[int]*fakePacketConn
	conns         map[*pipeConn]struct{}
	nextPort      int
	isUnreachable bool
	isLowID       bool
	isClosed      bool
	// isUDPFirewalled hosts hear datagrams only from the IPs in udpPeers,
	// those they sent one to.
	isUDPFirewalled bool
	udpPeers        map[netip.Addr]bool
}

// SetUnreachable makes dials to h fail and datagrams to h vanish, as for a
// host that went offline. h can still dial out.
func (h *Host) SetUnreachable(isUnreachable bool) {
	h.network.mu.Lock()
	defer h.network.mu.Unlock()
	h.isUnreachable = isUnreachable
}

// SetLowID makes h refuse incoming TCP connections, as behind a NAT without a
// forwarded port. Datagrams still arrive.
func (h *Host) SetLowID(isLowID bool) {
	h.network.mu.Lock()
	defer h.network.mu.Unlock()
	h.isLowID = isLowID
}

// SetUDPFirewalled makes h drop datagrams from addresses it never sent one
// to, as a NAT does.
func (h *Host) SetUDPFirewalled(isUDPFirewalled bool) {
	h.network.mu.Lock()
	defer h.network.mu.Unlock()
	h.isUDPFirewalled = isUDPFirewalled
}

// Close closes every listener, connection and UDP socket of h and takes it
// off the network.
func (h *Host) Close() {
	n := h.network
	n.mu.Lock()
	h.isClosed = true
	for _, addr := range h.addrs {
		delete(n.hosts, addr)
	}
	listeners, sockets, conns := h.listeners, h.sockets, h.conns
	h.listeners, h.sockets, h.conns = map[int]*fakeListener{}, map[int]*fakePacketConn{}, map[*pipeConn]struct{}{}
	n.mu.Unlock()
	for _, l := range listeners {
		l.Close()
	}
	for _, s := range sockets {
		s.Close()
	}
	for c := range conns {
		c.Close()
	}
}

func (h *Host) OpenTCP(ctx context.Context, addr netip.AddrPort) (net.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	addr = netip.AddrPortFrom(addr.Addr().Unmap(), addr.Port())
	n := h.network
	n.mu.Lock()
	defer n.mu.Unlock()
	if h.isClosed {
		return nil, net.ErrClosed
	}
	fail := func(errno syscall.Errno) error {
		return &net.OpError{Op: "dial", Net: "tcp", Addr: net.TCPAddrFromAddrPort(addr), Err: errno}
	}
	local, ok := h.addrByFamily(addr.Addr())
	if !ok {
		return nil, fail(syscall.ENETUNREACH)
	}
	target := n.hosts[addr.Addr()]
	if target == nil || target.isUnreachable {
		return nil, fail(syscall.EHOSTUNREACH)
	}
	listener := target.listeners[int(addr.Port())]
	if target.isLowID || listener == nil || len(listener.queue) == cap(listener.queue) {
		return nil, fail(syscall.ECONNREFUSED)
	}
	client, server := createPipe(netip.AddrPortFrom(local, uint16(h.createPort())), addr)
	h.addConn(client)
	target.addConn(server)
	listener.queue <- server
	return client, nil
}

func (h *Host) LookupHost(ctx context.Context, host string) ([]netip.Addr, error) {
	h.network.mu.Lock()
	defer h.network.mu.Unlock()
	addr, ok := h.network.names[host]
	if !ok || !addr.Is4() {
		return nil, &net.DNSError{Err: "no such host", Name: host, IsNotFound: true}
	}
	return []netip.Addr{addr}, nil
}

func (h *Host) OpenListener(port int) (Listener, error) {
	n := h.network
	n.mu.Lock()
	defer n.mu.Unlock()
	if h.isClosed {
		return nil, net.ErrClosed
	}
	if port == 0 {
		port = h.createPort()
	}
	if _, ok := h.listeners[port]; ok {
		return nil, &net.OpError{Op: "listen", Net: "tcp", Err: syscall.EADDRINUSE}
	}
	l := &fakeListener{host: h, port: port, queue: make(chan *pipeConn, acceptBacklog), done: make(chan struct{})}
	h.listeners[port] = l
	return l, nil
}

func (h *Host) OpenUDP(port int) (PacketConn, error) {
	n := h.network
	n.mu.Lock()
	defer n.mu.Unlock()
	if h.isClosed {
		return nil, net.ErrClosed
	}
	if port == 0 {
		port = h.createPort()
	}
	if _, ok := h.sockets[port]; ok {
		return nil, &net.OpError{Op: "listen", Net: "udp", Err: syscall.EADDRINUSE}
	}
	s := &fakePacketConn{host: h, port: port, queue: make(chan datagram, udpQueueSize), done: make(chan struct{})}
	h.sockets[port] = s
	return s, nil
}

// addrByFamily is h's first address of the same family as to.
func (h *Host) addrByFamily(to netip.Addr) (netip.Addr, bool) {
	for _, addr := range h.addrs {
		if addr.Is4() == to.Is4() {
			return addr, true
		}
	}
	return netip.Addr{}, false
}

func (h *Host) createPort() int {
	for {
		port := h.nextPort
		h.nextPort++
		if h.nextPort > 65535 {
			h.nextPort = firstEphemeralPort
		}
		_, isListening := h.listeners[port]
		_, isBound := h.sockets[port]
		if !isListening && !isBound {
			return port
		}
	}
}

func (h *Host) addConn(c *pipeConn) {
	h.conns[c] = struct{}{}
	c.onClosed = func() {
		h.network.mu.Lock()
		defer h.network.mu.Unlock()
		delete(h.conns, c)
	}
}

type fakeListener struct {
	host      *Host
	port      int
	queue     chan *pipeConn
	done      chan struct{}
	closeOnce sync.Once
}

func (l *fakeListener) Accept() (net.Conn, netip.AddrPort, error) {
	select {
	case c := <-l.queue:
		return c, c.remote.AddrPort(), nil
	case <-l.done:
		return nil, netip.AddrPort{}, net.ErrClosed
	}
}

func (l *fakeListener) Close() error {
	err := net.ErrClosed
	l.closeOnce.Do(func() {
		n := l.host.network
		n.mu.Lock()
		if l.host.listeners[l.port] == l {
			delete(l.host.listeners, l.port)
		}
		n.mu.Unlock()
		close(l.done)
		for {
			select {
			case c := <-l.queue:
				c.Close()
			default:
				err = nil
				return
			}
		}
	})
	return err
}

func (l *fakeListener) Port() int { return l.port }

type datagram struct {
	from    netip.AddrPort
	payload []byte
}

type fakePacketConn struct {
	host      *Host
	port      int
	queue     chan datagram
	done      chan struct{}
	closeOnce sync.Once
}

func (s *fakePacketConn) ReadFrom(b []byte) (int, netip.AddrPort, error) {
	select {
	case <-s.done:
		return 0, netip.AddrPort{}, net.ErrClosed
	default:
	}
	select {
	case d := <-s.queue:
		return copy(b, d.payload), d.from, nil
	case <-s.done:
		return 0, netip.AddrPort{}, net.ErrClosed
	}
}

// WriteTo drops datagrams the way UDP does: to unknown or unreachable hosts,
// closed ports, and full receive queues.
func (s *fakePacketConn) WriteTo(b []byte, addr netip.AddrPort) (int, error) {
	addr = netip.AddrPortFrom(addr.Addr().Unmap(), addr.Port())
	h := s.host
	n := h.network
	n.mu.Lock()
	defer n.mu.Unlock()
	select {
	case <-s.done:
		return 0, net.ErrClosed
	default:
	}
	local, ok := h.addrByFamily(addr.Addr())
	if !ok {
		return 0, &net.OpError{Op: "write", Net: "udp", Addr: net.UDPAddrFromAddrPort(addr), Err: syscall.ENETUNREACH}
	}
	h.udpPeers[addr.Addr()] = true
	target := n.hosts[addr.Addr()]
	if target == nil || target.isUnreachable || target.isUDPFirewalled && !target.udpPeers[local] {
		return len(b), nil
	}
	socket := target.sockets[int(addr.Port())]
	if socket == nil {
		return len(b), nil
	}
	select {
	case socket.queue <- datagram{from: netip.AddrPortFrom(local, uint16(s.port)), payload: append([]byte(nil), b...)}:
	default:
	}
	return len(b), nil
}

func (s *fakePacketConn) Close() error {
	err := net.ErrClosed
	s.closeOnce.Do(func() {
		n := s.host.network
		n.mu.Lock()
		if s.host.sockets[s.port] == s {
			delete(s.host.sockets, s.port)
		}
		n.mu.Unlock()
		close(s.done)
		err = nil
	})
	return err
}

func (s *fakePacketConn) Port() int { return s.port }
