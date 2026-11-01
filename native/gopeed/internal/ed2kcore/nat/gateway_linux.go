package nat

import (
	"context"
	"net/netip"
	"os"
)

// probeGateway reads the kernel routing table from procfs. Android 10+
// denies /proc/net to apps; Open then falls back to UPnP.
func probeGateway(ctx context.Context, isIPv6 bool) (netip.Addr, error) {
	if isIPv6 {
		data, err := os.ReadFile("/proc/net/ipv6_route")
		if err != nil {
			return netip.Addr{}, err
		}
		return parseProcIPv6Route(string(data))
	}
	data, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return netip.Addr{}, err
	}
	return parseProcRoute(string(data))
}
