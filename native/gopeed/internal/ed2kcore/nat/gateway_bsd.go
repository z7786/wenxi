//go:build darwin || freebsd || netbsd || openbsd || dragonfly

package nat

import (
	"context"
	"net/netip"
	"os/exec"
)

// probeGateway asks route(8): its output is not localized and is the same
// on macOS and the BSDs, which a routing-socket parser would have to handle
// per kernel (KAME-embedded scope ids, sockaddr padding).
func probeGateway(ctx context.Context, isIPv6 bool) (netip.Addr, error) {
	args := []string{"-n", "get", "default"}
	if isIPv6 {
		args = []string{"-n", "get", "-inet6", "default"}
	}
	output, err := exec.CommandContext(ctx, "/sbin/route", args...).Output()
	if err != nil {
		return netip.Addr{}, err
	}
	return parseRouteGet(string(output))
}
