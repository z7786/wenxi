package kad

import (
	"net/netip"
	"reflect"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	kadwire "github.com/GopeedLab/gopeed/internal/ed2kcore/wire/kad"
)

// aMule PacketTracking.cpp:107-240 and protocol/ed2k/Constants.h.
const (
	// An IP whose requests of one kind run five times past their limit
	// floods on purpose and is ignored for CLIENTBANTIME.
	floodBanFactor = 5
	floodBan       = 2 * time.Hour
)

type floodKey struct {
	ip   netip.Addr
	kind reflect.Type
}

// flood is aMule's incoming request tracking: each IP may send each kind of
// request only so often a minute; more are dropped unanswered, and an IP far
// past the limit is ignored altogether for a while. Without it any spoofed
// sender could have us send twenty contacts to its victim for a two-byte
// BootstrapReq, or have the engine connect to the victim for a
// FirewalledReq.
type flood struct {
	// due is when an IP's requests of a kind will have drained at the
	// allowed rate; a request pushes it on by one interval even when it is
	// dropped, as aMule counts those too. It must outlive the packet: the
	// rate is over a minute of packets.
	due map[floodKey]time.Time
	// banned holds each banned IP until its ban ends. Unlike due it is per
	// IP: a ban drops every packet from it, responses too.
	banned map[netip.Addr]time.Time
}

func buildFlood() flood {
	return flood{due: map[floodKey]time.Time{}, banned: map[netip.Addr]time.Time{}}
}

// requestsPerMinute is how many requests of p's kind one IP may send a
// minute, 0 for responses, which only match requests we sent. Both firewall
// requests count as one kind.
func requestsPerMinute(p wire.Packet) (kind reflect.Type, perMinute int) {
	kind = reflect.TypeOf(p)
	switch p.(type) {
	case kadwire.BootstrapReq, kadwire.PublishSourcesReq, kadwire.FindBuddyReq, kadwire.Ping:
		return kind, 2
	case kadwire.HelloReq, kadwire.SearchSourcesReq:
		return kind, 3
	case kadwire.Req:
		return kind, 10
	case kadwire.CallbackReq:
		return kind, 1
	case kadwire.FirewalledReq, kadwire.LegacyFirewalledReq:
		return reflect.TypeFor[kadwire.FirewalledReq](), 2
	}
	return nil, 0
}

// matchAllowed counts p from ip and tells whether to handle it.
func (f *flood) matchAllowed(ip netip.Addr, p wire.Packet, now time.Time) bool {
	if now.Before(f.banned[ip]) {
		return false
	}
	kind, perMinute := requestsPerMinute(p)
	if perMinute == 0 {
		return true
	}
	key := floodKey{ip, kind}
	due := later(f.due[key], now).Add(time.Minute / time.Duration(perMinute))
	f.due[key] = due
	switch backlog := due.Sub(now); {
	case backlog > floodBanFactor*time.Minute:
		f.banned[ip] = now.Add(floodBan)
		return false
	case backlog > time.Minute:
		return false
	}
	return true
}

func (f *flood) clearExpired(now time.Time) {
	for key, due := range f.due {
		if !now.Before(due) {
			delete(f.due, key)
		}
	}
	for ip, until := range f.banned {
		if !now.Before(until) {
			delete(f.banned, ip)
		}
	}
}
