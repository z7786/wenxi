package nat

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"time"
)

const (
	pcpPort    = 5351
	pcpVersion = 2
	pmpVersion = 0
	pcpOpMap   = 1
	isResponse = 0x80
	// RFC 6887 7: a PCP message never exceeds 1100 bytes.
	maxPCPLen = 1100
)

var (
	errNoAnswer           = errors.New("nat: gateway did not answer PCP or NAT-PMP")
	errUnsupportedVersion = errors.New("nat: gateway speaks NAT-PMP, not PCP")
)

// RFC 6887 7.4 result codes, indexed by value.
var pcpResults = []string{
	"SUCCESS", "UNSUPP_VERSION", "NOT_AUTHORIZED", "MALFORMED_REQUEST", "UNSUPP_OPCODE",
	"UNSUPP_OPTION", "MALFORMED_OPTION", "NETWORK_FAILURE", "NO_RESOURCES", "UNSUPP_PROTOCOL",
	"USER_EX_QUOTA", "CANNOT_PROVIDE_EXTERNAL", "ADDRESS_MISMATCH", "EXCESSIVE_REMOTE_PEERS",
}

// RFC 6886 3.5 result codes, indexed by value.
var pmpResults = []string{
	"Success", "Unsupported Version", "Not Authorized/Refused", "Network Failure",
	"Out of resources", "Unsupported opcode",
}

type portMapper interface {
	addMapping(ctx context.Context, m mapping, lifetime time.Duration) (time.Duration, netip.Addr, error)
	deleteMapping(ctx context.Context, m mapping) error
}

// gateway is a UDP conversation with one PCP or NAT-PMP server.
type gateway struct {
	conn   *net.UDPConn
	timing timing
}

type pcp struct {
	*gateway
	clientIP netip.Addr
	nonce    [12]byte
}

type pmp struct {
	*gateway
}

// openLease adds wanted on the gateway of r and keeps the mappings alive
// until the returned function deletes them.
func openLease(ctx context.Context, r route, wanted []mapping, t timing) (func(context.Context) error, netip.Addr, error) {
	var local *net.UDPAddr
	if r.local.IsValid() {
		local = net.UDPAddrFromAddrPort(netip.AddrPortFrom(r.local, 0))
	}
	conn, err := net.DialUDP("udp", local, net.UDPAddrFromAddrPort(r.gateway))
	if err != nil {
		return nil, netip.Addr{}, fmt.Errorf("%w: %w", errNoAnswer, err)
	}
	g := &gateway{conn: conn, timing: t}
	// The PCP client address must equal the request's source address
	// (RFC 6887 8.1), which only the socket's local end reveals.
	client := pcp{gateway: g, clientIP: conn.LocalAddr().(*net.UDPAddr).AddrPort().Addr().WithZone("")}
	rand.Read(client.nonce[:])
	var mapper portMapper = client

	var added []mapping
	var errs []error
	var external netip.Addr
	granted := t.lifetime
	for _, m := range wanted {
		lifetime, ip, err := mapper.addMapping(ctx, m, t.lifetime)
		if errors.Is(err, errUnsupportedVersion) && r.gateway.Addr().Is4() {
			mapper = pmp{g}
			lifetime, ip, err = mapper.addMapping(ctx, m, t.lifetime)
		}
		if err != nil {
			errs = append(errs, err)
			if errors.Is(err, errNoAnswer) || errors.Is(err, errUnsupportedVersion) || ctx.Err() != nil {
				break
			}
			continue
		}
		added = append(added, m)
		granted = min(granted, lifetime)
		if !external.IsValid() {
			external = ip
		}
	}
	if len(added) == 0 {
		conn.Close()
		return nil, netip.Addr{}, errors.Join(errs...)
	}

	refreshCtx, stop := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		refreshMappings(refreshCtx, mapper, added, time.Now().Add(granted), t)
	}()
	closeLease := func(ctx context.Context) error {
		stop()
		<-done
		defer conn.Close()
		var errs []error
		for _, m := range added {
			errs = append(errs, mapper.deleteMapping(ctx, m))
		}
		return errors.Join(errs...)
	}
	return closeLease, external, nil
}

// refreshMappings renews every mapping at half of what is left of its
// lifetime (RFC 6887 11.2.1, RFC 6886 3.3). A refresh also recreates a
// mapping the gateway lost in a reboot, so epoch tracking is not needed.
func refreshMappings(ctx context.Context, mapper portMapper, mappings []mapping, expiry time.Time, t timing) {
	hasFailed := false
	for {
		wait := time.Until(expiry) / 2
		if hasFailed {
			wait = max(wait, t.minWait)
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		now := time.Now()
		shortest := t.lifetime
		hasFailed = false
		for _, m := range mappings {
			lifetime, _, err := mapper.addMapping(ctx, m, t.lifetime)
			if err != nil {
				hasFailed = true
				lifetime = expiry.Sub(now)
			}
			shortest = min(shortest, lifetime)
		}
		expiry = now.Add(shortest)
	}
}

// fetchReply sends request and retransmits it, doubling the pause, until
// isReply accepts an answer or the timing window ends.
func (g *gateway) fetchReply(ctx context.Context, request []byte, isReply func([]byte) bool) ([]byte, error) {
	deadline := time.Now().Add(g.timing.window)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	stop := context.AfterFunc(ctx, func() { g.conn.SetReadDeadline(time.Now()) })
	defer stop()

	wait := g.timing.retry
	buffer := make([]byte, maxPCPLen)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if !time.Now().Before(deadline) {
			return nil, errNoAnswer
		}
		if _, err := g.conn.Write(request); err != nil {
			return nil, fmt.Errorf("%w: %w", errNoAnswer, err)
		}
		g.conn.SetReadDeadline(time.Now().Add(min(wait, time.Until(deadline))))
		wait *= 2
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		for {
			n, err := g.conn.Read(buffer)
			if err == nil {
				if isReply(buffer[:n]) {
					return bytes.Clone(buffer[:n]), nil
				}
				continue
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				break
			}
			// An ICMP port unreachable surfaces here as a refused read:
			// nothing listens on 5351.
			return nil, fmt.Errorf("%w: %w", errNoAnswer, err)
		}
	}
}

func toProtocolNumber(protocol string) byte {
	if protocol == "TCP" {
		return 6
	}
	return 17
}

func (p pcp) addMapping(ctx context.Context, m mapping, lifetime time.Duration) (time.Duration, netip.Addr, error) {
	granted, external, err := p.requestMap(ctx, m, uint32(lifetime/time.Second))
	if err != nil {
		return 0, netip.Addr{}, err
	}
	if granted == 0 {
		return 0, netip.Addr{}, fmt.Errorf("nat: PCP MAP %s %d: gateway granted no lifetime", m.protocol, m.port)
	}
	// eD2k peers and servers only learn our internal port, so another
	// external port is useless.
	if int(external.Port()) != m.port {
		p.requestMap(ctx, m, 0)
		return 0, netip.Addr{}, fmt.Errorf("nat: PCP MAP %s %d: gateway assigned external port %d", m.protocol, m.port, external.Port())
	}
	return time.Duration(granted) * time.Second, external.Addr(), nil
}

func (p pcp) deleteMapping(ctx context.Context, m mapping) error {
	_, _, err := p.requestMap(ctx, m, 0)
	return err
}

// requestMap sends a PCP MAP request (RFC 6887 11.1) and returns the
// granted lifetime in seconds and the external address.
func (p pcp) requestMap(ctx context.Context, m mapping, lifetime uint32) (uint32, netip.AddrPort, error) {
	request := make([]byte, 60)
	request[0] = pcpVersion
	request[1] = pcpOpMap
	binary.BigEndian.PutUint32(request[4:], lifetime)
	clientIP := p.clientIP.As16()
	copy(request[8:24], clientIP[:])
	copy(request[24:36], p.nonce[:])
	request[36] = toProtocolNumber(m.protocol)
	binary.BigEndian.PutUint16(request[40:], uint16(m.port))
	binary.BigEndian.PutUint16(request[42:], uint16(m.port))
	// The suggested external address is the all-zeros address of the
	// client's family, which for IPv4 is ::ffff:0.0.0.0 (RFC 6887 11.1).
	if p.clientIP.Is4() {
		request[54], request[55] = 0xff, 0xff
	}

	reply, err := p.fetchReply(ctx, request, func(reply []byte) bool {
		if len(reply) >= 4 && reply[0] == pmpVersion {
			return true
		}
		if len(reply) < 24 || reply[0] != pcpVersion || reply[1] != isResponse|pcpOpMap {
			return false
		}
		// An error answer to a request the server could not parse may lack
		// the opcode data (RFC 6887 8.3).
		if len(reply) < 60 {
			return reply[3] != 0
		}
		return bytes.Equal(reply[24:36], request[24:36]) && reply[36] == request[36] && bytes.Equal(reply[40:42], request[40:42])
	})
	if err != nil {
		return 0, netip.AddrPort{}, err
	}
	if reply[0] == pmpVersion {
		return 0, netip.AddrPort{}, errUnsupportedVersion
	}
	if result := reply[3]; result != 0 {
		return 0, netip.AddrPort{}, fmt.Errorf("nat: PCP MAP %s %d: %s", m.protocol, m.port, toResultText(pcpResults, int(result)))
	}
	external := netip.AddrFrom16([16]byte(reply[44:60])).Unmap()
	return binary.BigEndian.Uint32(reply[4:8]), netip.AddrPortFrom(external, binary.BigEndian.Uint16(reply[42:44])), nil
}

func toResultText(names []string, code int) string {
	if code < len(names) {
		return names[code]
	}
	return fmt.Sprintf("result %d", code)
}

// addMapping also fetches the external address, which a NAT-PMP mapping
// answer does not carry.
func (p pmp) addMapping(ctx context.Context, m mapping, lifetime time.Duration) (time.Duration, netip.Addr, error) {
	granted, externalPort, err := p.requestMap(ctx, m, uint16(m.port), uint32(lifetime/time.Second))
	if err != nil {
		return 0, netip.Addr{}, err
	}
	if granted == 0 {
		return 0, netip.Addr{}, fmt.Errorf("nat: NAT-PMP map %s %d: gateway granted no lifetime", m.protocol, m.port)
	}
	if int(externalPort) != m.port {
		p.requestMap(ctx, m, 0, 0)
		return 0, netip.Addr{}, fmt.Errorf("nat: NAT-PMP map %s %d: gateway assigned external port %d", m.protocol, m.port, externalPort)
	}
	external, _ := p.fetchExternalIP(ctx)
	return time.Duration(granted) * time.Second, external, nil
}

// deleteMapping sends lifetime 0 and external port 0 (RFC 6886 3.4).
func (p pmp) deleteMapping(ctx context.Context, m mapping) error {
	_, _, err := p.requestMap(ctx, m, 0, 0)
	return err
}

// requestMap sends a NAT-PMP mapping request (RFC 6886 3.3) and returns the
// granted lifetime in seconds and the mapped external port.
func (p pmp) requestMap(ctx context.Context, m mapping, externalPort uint16, lifetime uint32) (uint32, uint16, error) {
	op := byte(1)
	if m.protocol == "TCP" {
		op = 2
	}
	request := make([]byte, 12)
	request[0] = pmpVersion
	request[1] = op
	binary.BigEndian.PutUint16(request[4:], uint16(m.port))
	binary.BigEndian.PutUint16(request[6:], externalPort)
	binary.BigEndian.PutUint32(request[8:], lifetime)

	reply, err := p.fetchReply(ctx, request, func(reply []byte) bool {
		if len(reply) < 4 || reply[0] != pmpVersion || reply[1] != isResponse|op {
			return false
		}
		if len(reply) < 16 {
			return binary.BigEndian.Uint16(reply[2:4]) != 0
		}
		return bytes.Equal(reply[8:10], request[4:6])
	})
	if err != nil {
		return 0, 0, err
	}
	if result := binary.BigEndian.Uint16(reply[2:4]); result != 0 {
		return 0, 0, fmt.Errorf("nat: NAT-PMP map %s %d: %s", m.protocol, m.port, toResultText(pmpResults, int(result)))
	}
	return binary.BigEndian.Uint32(reply[12:16]), binary.BigEndian.Uint16(reply[10:12]), nil
}

func (p pmp) fetchExternalIP(ctx context.Context) (netip.Addr, error) {
	reply, err := p.fetchReply(ctx, []byte{pmpVersion, 0}, func(reply []byte) bool {
		return len(reply) >= 4 && reply[0] == pmpVersion && reply[1] == isResponse
	})
	if err != nil {
		return netip.Addr{}, err
	}
	if result := binary.BigEndian.Uint16(reply[2:4]); result != 0 {
		return netip.Addr{}, fmt.Errorf("nat: NAT-PMP external address: %s", toResultText(pmpResults, int(result)))
	}
	if len(reply) < 12 {
		return netip.Addr{}, errors.New("nat: NAT-PMP external address: short answer")
	}
	ip := netip.AddrFrom4([4]byte(reply[8:12]))
	if ip.IsUnspecified() {
		return netip.Addr{}, errors.New("nat: gateway reports no external address")
	}
	return ip, nil
}
