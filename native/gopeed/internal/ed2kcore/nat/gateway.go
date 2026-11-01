package nat

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

// probeGlobalIPv6 returns the source address the OS picks for a global IPv6
// destination, or the zero Addr when it has no global one. Dialing UDP only
// consults the routing table; no packet is sent to the documentation address.
func probeGlobalIPv6() netip.Addr {
	conn, err := net.Dial("udp6", "[2001:db8::1]:9")
	if err != nil {
		return netip.Addr{}
	}
	defer conn.Close()
	ip := conn.LocalAddr().(*net.UDPAddr).AddrPort().Addr()
	if !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return netip.Addr{}
	}
	return ip.WithZone("")
}

// parseProcRoute picks the lowest-metric default gateway from Linux's
// /proc/net/route, whose addresses are hex in host (little-endian) order.
func parseProcRoute(text string) (netip.Addr, error) {
	var best netip.Addr
	bestMetric := -1
	scanner := bufio.NewScanner(strings.NewReader(text))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 8 || fields[1] != "00000000" || fields[7] != "00000000" {
			continue
		}
		flags, err := strconv.ParseUint(fields[3], 16, 32)
		if err != nil || flags&0x3 != 0x3 { // RTF_UP | RTF_GATEWAY
			continue
		}
		gateway, err := strconv.ParseUint(fields[2], 16, 32)
		metric, metricErr := strconv.Atoi(fields[6])
		if err != nil || metricErr != nil {
			continue
		}
		var ip [4]byte
		binary.LittleEndian.PutUint32(ip[:], uint32(gateway))
		if bestMetric < 0 || metric < bestMetric {
			best, bestMetric = netip.AddrFrom4(ip), metric
		}
	}
	if !best.IsValid() {
		return netip.Addr{}, errors.New("nat: no IPv4 default route")
	}
	return best, nil
}

// parseProcIPv6Route picks the lowest-metric default gateway from Linux's
// /proc/net/ipv6_route; the gateway is usually link-local, so it carries the
// interface as its zone.
func parseProcIPv6Route(text string) (netip.Addr, error) {
	var best netip.Addr
	var bestMetric uint64
	scanner := bufio.NewScanner(strings.NewReader(text))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 10 || fields[1] != "00" || strings.Trim(fields[0], "0") != "" {
			continue
		}
		flags, err := strconv.ParseUint(fields[8], 16, 32)
		if err != nil || flags&0x3 != 0x3 { // RTF_UP | RTF_GATEWAY
			continue
		}
		raw, err := hex.DecodeString(fields[4])
		metric, metricErr := strconv.ParseUint(fields[5], 16, 32)
		if err != nil || metricErr != nil || len(raw) != 16 {
			continue
		}
		ip := netip.AddrFrom16([16]byte(raw))
		if ip.IsUnspecified() {
			continue
		}
		if ip.IsLinkLocalUnicast() {
			ip = ip.WithZone(fields[9])
		}
		if !best.IsValid() || metric < bestMetric {
			best, bestMetric = ip, metric
		}
	}
	if !best.IsValid() {
		return netip.Addr{}, errors.New("nat: no IPv6 default route")
	}
	return best, nil
}

// parseRouteGet reads the gateway line of BSD `route -n get default`.
func parseRouteGet(text string) (netip.Addr, error) {
	scanner := bufio.NewScanner(strings.NewReader(text))
	for scanner.Scan() {
		name, value, ok := strings.Cut(strings.TrimSpace(scanner.Text()), ":")
		if !ok || name != "gateway" {
			continue
		}
		return netip.ParseAddr(strings.TrimSpace(value))
	}
	return netip.Addr{}, errors.New("nat: route output has no gateway")
}
