package transport

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"net/url"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// The issues Proxied reports, as docs/protocol.md names them in Network.
const (
	issueUnreachable = "unreachable"
	issueNoUDP       = "noUdp"
)

var errRemoteDNS = errors.New("socks5h resolves host names only while connecting")

const (
	socksVersion   = 5
	authNone       = 0
	authPassword   = 2
	authRejected   = 0xFF
	cmdConnect     = 1
	cmdAssociate   = 3
	atypIPv4       = 1
	atypDomain     = 3
	atypIPv6       = 4
	replySucceeded = 0
	// Replies about the target host, not about the Proxy or our link
	// (RFC 1928 section 6).
	replyHostUnreachable = 4
	replyRefused         = 5
	replyTTLExpired      = 6
	replyNotSupported    = 7
	handshakeTimeout     = 30 * time.Second
	associateRetryMin    = 5 * time.Second
	associateRetryMax    = 5 * time.Minute
	// A relay that has carried nothing back after this many datagrams and
	// this long is taken for one that drops UDP: RFC 1928 lets a relay
	// accept an association and then drop silently, as mihomo does with
	// udp: false. Kad and server UDP ask many peers, so a working relay
	// answers well within it.
	silentAfterSent = 20
	silentAfter     = 30 * time.Second
	// udpHeaderMax is RSV, FRAG, ATYP, an IPv6 address, and a port.
	udpHeaderMax = 3 + 1 + 16 + 2
)

type proxy struct {
	direct             Transport
	host               string
	port               uint16
	user, password     string
	isRemoteResolution bool
	retryMin, retryMax time.Duration
	silentAfter        time.Duration
	onIssue            func(issue string)
	// isHeard is whether any relay of this Proxy carried a datagram back;
	// once it has, sending checks nothing more.
	isHeard atomic.Bool

	mu        sync.Mutex
	isTCPDown bool
	udpDown   map[*relayConn]bool
	sent      int
	firstSent time.Time
	isSilent  bool
	lastIssue string
}

// proxyError is a failure to reach or talk to the Proxy itself.
type proxyError struct{ err error }

func (e proxyError) Error() string { return "proxy: " + e.err.Error() }
func (e proxyError) Unwrap() error { return e.err }

// replyError is the Proxy's answer that it could not carry a request.
type replyError struct{ code byte }

func (e replyError) Error() string { return fmt.Sprintf("proxy reply %d", e.code) }

// Proxied returns a Transport that sends everything through the SOCKS5 Proxy
// at proxyURL, socks5:// or socks5h://, as ADR-0006 describes. It listens for
// TCP through direct, and reaches the Proxy through direct.
//
// Its UDP sockets keep themselves associated: while the Proxy relays no UDP
// they drop what is written and hear nothing, and they associate again with
// backoff. onIssue hears each change of what is wrong, "unreachable", "noUdp"
// or "" once all is well; it must not block.
func Proxied(direct Transport, proxyURL string, onIssue func(issue string)) (Transport, error) {
	u, err := url.Parse(proxyURL)
	if err != nil {
		return nil, err
	}
	if u.Scheme != "socks5" && u.Scheme != "socks5h" {
		return nil, fmt.Errorf("unsupported proxy scheme %q", u.Scheme)
	}
	port := uint64(1080)
	if u.Port() != "" {
		if port, err = strconv.ParseUint(u.Port(), 10, 16); err != nil {
			return nil, fmt.Errorf("proxy port: %w", err)
		}
	}
	if u.Hostname() == "" {
		return nil, errors.New("proxy has no host")
	}
	p := &proxy{
		direct:             direct,
		host:               u.Hostname(),
		port:               uint16(port),
		user:               u.User.Username(),
		isRemoteResolution: u.Scheme == "socks5h",
		retryMin:           associateRetryMin,
		retryMax:           associateRetryMax,
		silentAfter:        silentAfter,
		onIssue:            onIssue,
		udpDown:            map[*relayConn]bool{},
	}
	p.password, _ = u.User.Password()
	return p, nil
}

// isProxyDown reports whether a failure was reaching or talking to the Proxy,
// which says nothing about the target.
func isProxyDown(err error) bool {
	var pe proxyError
	return errors.As(err, &pe)
}

func (p *proxy) OpenListener(port int) (Listener, error) { return p.direct.OpenListener(port) }

func (p *proxy) LookupHost(ctx context.Context, host string) ([]netip.Addr, error) {
	if p.isRemoteResolution {
		return nil, errRemoteDNS
	}
	return p.direct.LookupHost(ctx, host)
}

func (p *proxy) OpenTCP(ctx context.Context, addr netip.AddrPort) (net.Conn, error) {
	conn, _, err := p.request(ctx, cmdConnect, addr)
	p.setTCPDown(isProxyDown(err))
	return conn, err
}

func (p *proxy) OpenUDP(port int) (PacketConn, error) {
	local, err := p.direct.OpenUDP(port)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	c := &relayConn{proxy: p, local: local, cancel: cancel}
	control, relay, err := p.associate(ctx)
	if err == nil {
		// Held before returning, so the first datagrams have a relay.
		c.control, c.relay = control, relay
	}
	go c.keepAssociated(ctx, control, relay, err)
	return c, nil
}

// associate asks for a UDP relay. An unspecified relay, or one named by
// host, means the Proxy's own address; some servers answer so when they
// relay on the address we reached them at.
func (p *proxy) associate(ctx context.Context) (net.Conn, netip.AddrPort, error) {
	ctx, cancel := context.WithTimeout(ctx, handshakeTimeout)
	defer cancel()
	control, relay, err := p.request(ctx, cmdAssociate, netip.AddrPortFrom(netip.IPv4Unspecified(), 0))
	p.setTCPDown(isProxyDown(err))
	if err != nil {
		return nil, netip.AddrPort{}, err
	}
	if relay.Addr().IsUnspecified() {
		if remote, ok := control.RemoteAddr().(*net.TCPAddr); ok {
			relay = netip.AddrPortFrom(remote.AddrPort().Addr().Unmap(), relay.Port())
		}
	}
	return control, relay, nil
}

func (p *proxy) setTCPDown(isDown bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.isTCPDown = isDown
	p.report()
}

func (p *proxy) setUDPDown(c *relayConn, isDown bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if isDown {
		p.udpDown[c] = true
	} else {
		delete(p.udpDown, c)
	}
	p.report()
}

// onSent counts a datagram given to a relay until one comes back, and
// takes the Proxy for one that drops UDP if none has by silentAfterSent
// datagrams and silentAfter.
func (p *proxy) onSent() {
	if p.isHeard.Load() {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	if p.sent == 0 {
		p.firstSent = now
	}
	p.sent++
	if !p.isSilent && p.sent >= silentAfterSent && now.Sub(p.firstSent) >= p.silentAfter {
		p.isSilent = true
		p.report()
	}
}

func (p *proxy) onHeard() {
	if p.isHeard.Swap(true) {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.isSilent = false
	p.report()
}

// report tells onIssue what is wrong when that changes; a Proxy we cannot
// reach explains missing UDP too, so it comes first.
func (p *proxy) report() {
	issue := ""
	switch {
	case p.isTCPDown:
		issue = issueUnreachable
	case len(p.udpDown) > 0 || p.isSilent:
		issue = issueNoUDP
	}
	if issue != p.lastIssue {
		p.lastIssue = issue
		p.onIssue(issue)
	}
}

// request opens a connection to the Proxy and sends one command; for
// UDP ASSOCIATE the connection is the association's control connection.
func (p *proxy) request(ctx context.Context, cmd byte, addr netip.AddrPort) (net.Conn, netip.AddrPort, error) {
	conn, err := p.openProxyConn(ctx)
	if err != nil {
		return nil, netip.AddrPort{}, proxyError{err}
	}
	stop := context.AfterFunc(ctx, func() { conn.SetDeadline(time.Unix(1, 0)) })
	conn.SetDeadline(time.Now().Add(handshakeTimeout))
	bound, err := p.handshake(conn, cmd, addr)
	if !stop() && err == nil {
		err = proxyError{ctx.Err()}
	}
	if err != nil {
		conn.Close()
		return nil, netip.AddrPort{}, err
	}
	conn.SetDeadline(time.Time{})
	return conn, bound, nil
}

func (p *proxy) openProxyConn(ctx context.Context) (net.Conn, error) {
	addr, err := netip.ParseAddr(p.host)
	if err != nil {
		addrs, err := p.direct.LookupHost(ctx, p.host)
		if err != nil {
			return nil, err
		}
		if len(addrs) == 0 {
			return nil, fmt.Errorf("proxy host %s has no address", p.host)
		}
		addr = addrs[0]
	}
	return p.direct.OpenTCP(ctx, netip.AddrPortFrom(addr.Unmap(), p.port))
}

func (p *proxy) handshake(conn net.Conn, cmd byte, addr netip.AddrPort) (netip.AddrPort, error) {
	method := byte(authNone)
	if p.user != "" || p.password != "" {
		method = authPassword
	}
	if _, err := conn.Write([]byte{socksVersion, 1, method}); err != nil {
		return netip.AddrPort{}, proxyError{err}
	}
	var choice [2]byte
	if _, err := io.ReadFull(conn, choice[:]); err != nil {
		return netip.AddrPort{}, proxyError{err}
	}
	if choice[0] != socksVersion || choice[1] != method {
		return netip.AddrPort{}, proxyError{fmt.Errorf("proxy refused auth method %d", method)}
	}
	if method == authPassword {
		if err := p.authenticate(conn); err != nil {
			return netip.AddrPort{}, proxyError{err}
		}
	}
	if _, err := conn.Write(append([]byte{socksVersion, cmd, 0}, buildAddr(addr)...)); err != nil {
		return netip.AddrPort{}, proxyError{err}
	}
	return readReply(conn)
}

// authenticate is the username and password exchange of RFC 1929.
func (p *proxy) authenticate(conn net.Conn) error {
	if len(p.user) > 255 || len(p.password) > 255 {
		return errors.New("proxy user or password longer than 255 bytes")
	}
	msg := append([]byte{1, byte(len(p.user))}, p.user...)
	msg = append(append(msg, byte(len(p.password))), p.password...)
	if _, err := conn.Write(msg); err != nil {
		return err
	}
	var status [2]byte
	if _, err := io.ReadFull(conn, status[:]); err != nil {
		return err
	}
	if status[1] != 0 {
		return errors.New("proxy rejected the user or password")
	}
	return nil
}

// readReply reads a reply and its bound address; a bound address named by
// host comes back unspecified, since resolving it would leave directly.
func readReply(conn net.Conn) (netip.AddrPort, error) {
	var head [4]byte
	if _, err := io.ReadFull(conn, head[:]); err != nil {
		return netip.AddrPort{}, proxyError{err}
	}
	if head[0] != socksVersion {
		return netip.AddrPort{}, proxyError{fmt.Errorf("proxy replied version %d", head[0])}
	}
	var size int
	switch head[3] {
	case atypIPv4:
		size = 4
	case atypIPv6:
		size = 16
	case atypDomain:
		var n [1]byte
		if _, err := io.ReadFull(conn, n[:]); err != nil {
			return netip.AddrPort{}, proxyError{err}
		}
		size = int(n[0])
	default:
		return netip.AddrPort{}, proxyError{fmt.Errorf("proxy replied address type %d", head[3])}
	}
	body := make([]byte, size+2)
	if _, err := io.ReadFull(conn, body); err != nil {
		return netip.AddrPort{}, proxyError{err}
	}
	if head[1] != replySucceeded {
		return netip.AddrPort{}, replyError{head[1]}
	}
	port := binary.BigEndian.Uint16(body[size:])
	if head[3] == atypDomain {
		return netip.AddrPortFrom(netip.IPv4Unspecified(), port), nil
	}
	addr, _ := netip.AddrFromSlice(body[:size])
	return netip.AddrPortFrom(addr.Unmap(), port), nil
}

func buildAddr(addr netip.AddrPort) []byte {
	ip := addr.Addr().Unmap()
	var b []byte
	if ip.Is4() {
		b = append([]byte{atypIPv4}, ip.AsSlice()...)
	} else {
		b = append([]byte{atypIPv6}, ip.AsSlice()...)
	}
	return binary.BigEndian.AppendUint16(b, addr.Port())
}

// relayConn sends and receives datagrams through a UDP ASSOCIATE. It hears
// only the relay: datagrams sent straight to the local port are dropped.
type relayConn struct {
	proxy  *proxy
	local  PacketConn
	cancel context.CancelFunc
	once   sync.Once

	mu       sync.Mutex
	control  net.Conn
	relay    netip.AddrPort
	isClosed bool
}

var relayBuffers = sync.Pool{New: func() any { return new([64*1024 + udpHeaderMax]byte) }}

// keepAssociated holds an association while its control connection lasts,
// as RFC 1928 section 7 ties one to the other, and asks again with backoff
// whenever there is none. It starts from the first attempt's result.
func (c *relayConn) keepAssociated(ctx context.Context, control net.Conn, relay netip.AddrPort, err error) {
	delay := c.proxy.retryMin
	for {
		if err == nil {
			c.mu.Lock()
			if c.isClosed {
				c.mu.Unlock()
				control.Close()
				return
			}
			c.control, c.relay = control, relay
			c.mu.Unlock()
			c.proxy.setUDPDown(c, false)
			delay = c.proxy.retryMin
			io.Copy(io.Discard, control)
			c.mu.Lock()
			c.control, c.relay = nil, netip.AddrPort{}
			c.mu.Unlock()
		}
		if ctx.Err() != nil {
			c.proxy.setUDPDown(c, false)
			return
		}
		c.proxy.setUDPDown(c, true)
		select {
		case <-ctx.Done():
			c.proxy.setUDPDown(c, false)
			return
		case <-time.After(delay):
		}
		delay = min(delay*2, c.proxy.retryMax)
		control, relay, err = c.proxy.associate(ctx)
	}
}

func (c *relayConn) currentRelay() netip.AddrPort {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.relay
}

func (c *relayConn) ReadFrom(b []byte) (int, netip.AddrPort, error) {
	buf := relayBuffers.Get().(*[64*1024 + udpHeaderMax]byte)
	defer relayBuffers.Put(buf)
	for {
		n, from, err := c.local.ReadFrom(buf[:])
		if err != nil {
			return 0, netip.AddrPort{}, err
		}
		if relay := c.currentRelay(); !relay.IsValid() || from != relay {
			continue
		}
		source, payload, ok := parseRelayed(buf[:n])
		if !ok {
			continue
		}
		c.proxy.onHeard()
		return copy(b, payload), source, nil
	}
}

// parseRelayed splits a relayed datagram into its source and payload;
// fragments and host-named sources are not ours to handle.
func parseRelayed(d []byte) (netip.AddrPort, []byte, bool) {
	if len(d) < 4 || d[0] != 0 || d[1] != 0 || d[2] != 0 {
		return netip.AddrPort{}, nil, false
	}
	var size int
	switch d[3] {
	case atypIPv4:
		size = 4
	case atypIPv6:
		size = 16
	default:
		return netip.AddrPort{}, nil, false
	}
	if len(d) < 4+size+2 {
		return netip.AddrPort{}, nil, false
	}
	addr, _ := netip.AddrFromSlice(d[4 : 4+size])
	port := binary.BigEndian.Uint16(d[4+size:])
	return netip.AddrPortFrom(addr.Unmap(), port), d[4+size+2:], true
}

// WriteTo drops the datagram while there is no association, as a lossy
// link would.
func (c *relayConn) WriteTo(b []byte, addr netip.AddrPort) (int, error) {
	relay := c.currentRelay()
	if !relay.IsValid() {
		return len(b), nil
	}
	datagram := append(append([]byte{0, 0, 0}, buildAddr(addr)...), b...)
	if _, err := c.local.WriteTo(datagram, relay); err != nil {
		return 0, err
	}
	c.proxy.onSent()
	return len(b), nil
}

func (c *relayConn) Close() error {
	var err error
	c.once.Do(func() {
		c.cancel()
		c.mu.Lock()
		c.isClosed = true
		if c.control != nil {
			c.control.Close()
		}
		c.mu.Unlock()
		err = c.local.Close()
	})
	return err
}

func (c *relayConn) Port() int { return c.local.Port() }
