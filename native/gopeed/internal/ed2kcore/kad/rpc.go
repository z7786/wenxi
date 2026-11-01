// Derived from goed2k kad_rpc.go.

package kad

import (
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

type rpcKind int

const (
	rpcHello rpcKind = iota
	rpcBootstrap
	rpcFind
	rpcSearchSources
	rpcPublish
	rpcFirewall
	rpcPing
	rpcFindBuddy
	// rpcHelloAck is a HelloRes that asked for a HelloResAck.
	rpcHelloAck
)

// responseTimeout is how long a contact has to answer before it counts as
// failed: eMule's CContact::CheckingType gives a checked contact MIN2S(2).
const responseTimeout = 2 * time.Minute

// rpc is a request waiting for its response. Only responses that match one
// are accepted, so nobody can push contacts or sources at us unasked.
type rpc struct {
	kind   rpcKind
	node   Node
	target wire.Hash
	sent   time.Time
	lookup *lookup
}

type rpcs struct{ pending []*rpc }

func (p *rpcs) add(r *rpc) { p.pending = append(p.pending, r) }

// match finds the request a response answers. eMule tracks requests by IP
// only, since NATs may answer from another port; so do we. A search request
// stays open for more SearchRes packets until it times out.
func (p *rpcs) match(from netip.AddrPort, kind rpcKind, target wire.Hash) *rpc {
	for i, r := range p.pending {
		if r.kind != kind || r.node.Addr.Addr() != from.Addr() || r.target != target {
			continue
		}
		if kind == rpcSearchSources {
			return r
		}
		p.pending = slices.Delete(p.pending, i, i+1)
		return r
	}
	return nil
}

func (p *rpcs) hasPending(to netip.AddrPort, kind rpcKind) bool {
	return slices.ContainsFunc(p.pending, func(r *rpc) bool { return r.kind == kind && r.node.Addr == to })
}

func (p *rpcs) count(kind rpcKind) int {
	count := 0
	for _, r := range p.pending {
		if r.kind == kind {
			count++
		}
	}
	return count
}

// removeExpired removes and returns the requests whose time ran out.
func (p *rpcs) removeExpired(now time.Time) []*rpc {
	var expired []*rpc
	p.pending = slices.DeleteFunc(p.pending, func(r *rpc) bool {
		if now.Sub(r.sent) < responseTimeout {
			return false
		}
		expired = append(expired, r)
		return true
	})
	return expired
}
