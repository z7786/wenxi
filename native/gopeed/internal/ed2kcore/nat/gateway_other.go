//go:build !linux && !darwin && !freebsd && !netbsd && !openbsd && !dragonfly && !windows

package nat

import (
	"context"
	"errors"
	"net/netip"
)

func probeGateway(ctx context.Context, isIPv6 bool) (netip.Addr, error) {
	return netip.Addr{}, errors.New("nat: default gateway lookup not supported on this OS")
}
