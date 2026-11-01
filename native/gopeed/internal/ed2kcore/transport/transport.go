// Package transport is the engine's seam for TCP and UDP sockets.
//
// Listeners and UDP sockets are dual-stack: one socket serves IPv4 and IPv6,
// and both report an IPv4 peer as an IPv4 address, never IPv4-mapped.
package transport

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"syscall"
)

type Transport interface {
	OpenTCP(ctx context.Context, addr netip.AddrPort) (net.Conn, error)
	// OpenListener and OpenUDP pick a free port when port is 0.
	OpenListener(port int) (Listener, error)
	OpenUDP(port int) (PacketConn, error)
	// LookupHost resolves a host name to its IPv4 addresses.
	LookupHost(ctx context.Context, host string) ([]netip.Addr, error)
}

type Listener interface {
	// Accept returns the next connection and its peer's address.
	Accept() (net.Conn, netip.AddrPort, error)
	Close() error
	Port() int
}

type PacketConn interface {
	ReadFrom(b []byte) (int, netip.AddrPort, error)
	WriteTo(b []byte, addr netip.AddrPort) (int, error)
	Close() error
	Port() int
}

// IsRefused reports whether OpenTCP failed because the remote host refused
// the connection or never answered it, directly or as the Proxy reports:
// evidence about that host. Other failures, such as no route, no network,
// or a Proxy we cannot reach, are about our own link.
func IsRefused(err error) bool {
	if isProxyDown(err) {
		return false
	}
	var re replyError
	if errors.As(err, &re) {
		return re.code == replyHostUnreachable || re.code == replyRefused || re.code == replyTTLExpired
	}
	var dial *net.OpError
	if !errors.As(err, &dial) || dial.Op != "dial" {
		return false
	}
	return dial.Timeout() || errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.ETIMEDOUT) || isWindowsRefused(err)
}

// Real is the Transport of the running process.
type Real struct{}

func (Real) OpenTCP(ctx context.Context, addr netip.AddrPort) (net.Conn, error) {
	var dialer net.Dialer
	return dialer.DialContext(ctx, "tcp", addr.String())
}

func (Real) OpenListener(port int) (Listener, error) {
	listener, err := net.ListenTCP("tcp", &net.TCPAddr{Port: port})
	if err != nil {
		return nil, err
	}
	return realListener{listener}, nil
}

func (Real) OpenUDP(port int) (PacketConn, error) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{Port: port})
	if err != nil {
		return nil, err
	}
	return realPacketConn{conn}, nil
}

func (Real) LookupHost(ctx context.Context, host string) ([]netip.Addr, error) {
	addrs, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
	for i, a := range addrs {
		addrs[i] = a.Unmap()
	}
	return addrs, err
}

type realListener struct{ *net.TCPListener }

func (l realListener) Accept() (net.Conn, netip.AddrPort, error) {
	conn, err := l.AcceptTCP()
	if err != nil {
		return nil, netip.AddrPort{}, err
	}
	remote := conn.RemoteAddr().(*net.TCPAddr).AddrPort()
	return conn, netip.AddrPortFrom(remote.Addr().Unmap(), remote.Port()), nil
}

func (l realListener) Port() int { return l.Addr().(*net.TCPAddr).Port }

type realPacketConn struct{ conn *net.UDPConn }

func (c realPacketConn) ReadFrom(b []byte) (int, netip.AddrPort, error) {
	n, addr, err := c.conn.ReadFromUDPAddrPort(b)
	return n, netip.AddrPortFrom(addr.Addr().Unmap(), addr.Port()), err
}

func (c realPacketConn) WriteTo(b []byte, addr netip.AddrPort) (int, error) {
	return c.conn.WriteToUDPAddrPort(b, addr)
}

func (c realPacketConn) Close() error { return c.conn.Close() }

func (c realPacketConn) Port() int { return c.conn.LocalAddr().(*net.UDPAddr).Port }
