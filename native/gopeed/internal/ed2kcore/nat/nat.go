// Derived from goed2k upnp.go.

// Package nat opens Kelpie's listening ports on the home gateway so peers
// outside the NAT can connect in. It speaks PCP (RFC 6887) first, NAT-PMP
// (RFC 6886) when the gateway answers PCP with UNSUPP_VERSION, and UPnP IGD
// when neither answers. With a global IPv6 address it also asks the IPv6
// default gateway for a PCP pinhole.
package nat

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"time"
)

type mapping struct {
	protocol string
	port     int
}

// route is where one address family's PCP requests go.
type route struct {
	gateway netip.AddrPort // the PCP/NAT-PMP server; zero when the host has none
	local   netip.Addr     // the address to map; zero lets the OS choose
}

type timing struct {
	lifetime time.Duration // asked of the gateway for each mapping
	retry    time.Duration // first retransmission; it doubles each time
	window   time.Duration // how long one request waits for an answer
	minWait  time.Duration // shortest pause between refreshes after a failure
}

// RFC 6887 asks for a 3 s first retransmission, but a gateway on the LAN
// answers within milliseconds and every silent second delays the UPnP
// fallback; NAT-PMP's 250 ms schedule (RFC 6886 3.1) fits better.
var defaultTiming = timing{
	lifetime: 2 * time.Hour,
	retry:    250 * time.Millisecond,
	window:   1500 * time.Millisecond,
	minWait:  time.Minute,
}

// Open forwards tcpPort (TCP) and udpPort (UDP) on the gateway to this host,
// external port equal to internal port. A zero port is skipped. PCP and
// NAT-PMP mappings are refreshed at half their lifetime until the returned
// function stops refreshing and deletes them; UPnP mappings are permanent
// until that function deletes them. The external address is the IPv4 one the
// gateway reports, or the zero Addr when none does. Open succeeds when at
// least one mapping was added.
func Open(ctx context.Context, tcpPort, udpPort int, description string) (func(context.Context) error, netip.Addr, error) {
	var v4, v6 route
	if ip, err := probeGateway(ctx, false); err == nil {
		v4.gateway = netip.AddrPortFrom(ip, pcpPort)
	}
	if local := probeGlobalIPv6(); local.IsValid() {
		if ip, err := probeGateway(ctx, true); err == nil {
			v6 = route{gateway: netip.AddrPortFrom(ip, pcpPort), local: local}
		}
	}
	return openWith(ctx, v4, v6, probeLocations, tcpPort, udpPort, description, defaultTiming)
}

func openWith(ctx context.Context, v4, v6 route, probeUPnP func(context.Context) []string, tcpPort, udpPort int, description string, t timing) (func(context.Context) error, netip.Addr, error) {
	wanted := buildMappings(tcpPort, udpPort)
	if len(wanted) == 0 {
		return nil, netip.Addr{}, errors.New("nat: no port to open")
	}

	type opened struct {
		close func(context.Context) error
		err   error
	}
	v6Opened := make(chan opened, 1)
	go func() {
		if !v6.gateway.IsValid() {
			v6Opened <- opened{}
			return
		}
		closeLease, _, err := openLease(ctx, v6, wanted, t)
		v6Opened <- opened{closeLease, err}
	}()

	var closers []func(context.Context) error
	var errs []error
	var closeV4 func(context.Context) error
	var external netip.Addr
	err := errors.New("nat: no IPv4 default gateway")
	if v4.gateway.IsValid() {
		closeV4, external, err = openLease(ctx, v4, wanted, t)
	}
	if err == nil {
		closers = append(closers, closeV4)
	} else {
		errs = append(errs, err)
		if locations := probeUPnP(ctx); len(locations) == 0 {
			errs = append(errs, errors.New("nat: no UPnP gateway found"))
		} else if closeUPnP, ip, err := openAt(ctx, locations, wanted, description); err != nil {
			errs = append(errs, err)
		} else {
			closers = append(closers, closeUPnP)
			external = ip
		}
	}
	if r := <-v6Opened; r.err != nil {
		errs = append(errs, fmt.Errorf("nat: IPv6: %w", r.err))
	} else if r.close != nil {
		closers = append(closers, r.close)
	}

	if len(closers) == 0 {
		return nil, netip.Addr{}, errors.Join(errs...)
	}
	closeAll := func(ctx context.Context) error {
		var errs []error
		for _, c := range closers {
			errs = append(errs, c(ctx))
		}
		return errors.Join(errs...)
	}
	return closeAll, external, nil
}

func buildMappings(tcpPort, udpPort int) []mapping {
	var wanted []mapping
	if tcpPort > 0 {
		wanted = append(wanted, mapping{protocol: "TCP", port: tcpPort})
	}
	if udpPort > 0 {
		wanted = append(wanted, mapping{protocol: "UDP", port: udpPort})
	}
	return wanted
}

func openAt(ctx context.Context, locations []string, wanted []mapping, description string) (func(context.Context) error, netip.Addr, error) {
	var errs []error
	var services []service
	for _, location := range locations {
		found, err := fetchServices(ctx, location)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		services = append(services, found...)
	}

	type added struct {
		service service
		mapping
	}
	var addedList []added
	var external netip.Addr
	for _, s := range services {
		hasAdded := false
		for _, m := range wanted {
			if err := s.addMapping(ctx, m, description); err != nil {
				errs = append(errs, err)
				continue
			}
			addedList = append(addedList, added{s, m})
			hasAdded = true
		}
		if hasAdded && !external.IsValid() {
			if ip, err := s.fetchExternalIP(ctx); err == nil {
				external = ip
			}
		}
	}
	if len(addedList) == 0 {
		return nil, netip.Addr{}, fmt.Errorf("nat: no port mapping added on %d gateway(s): %w", len(locations), errors.Join(errs...))
	}

	closeMappings := func(ctx context.Context) error {
		var errs []error
		for _, a := range addedList {
			if err := a.service.deleteMapping(ctx, a.mapping); err != nil {
				errs = append(errs, err)
			}
		}
		return errors.Join(errs...)
	}
	return closeMappings, external, nil
}
