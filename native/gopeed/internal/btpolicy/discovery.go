package btpolicy

import (
	"encoding/hex"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/anacrolix/dht/v2"
	"github.com/anacrolix/dht/v2/krpc"
	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
	"golang.org/x/time/rate"
)

const DefaultUploadLimit int64 = 512 * 1024

var uploadLimiter = rate.NewLimiter(rate.Limit(DefaultUploadLimit), 64*1024)

// The same limiter covers downloads and playback clients without multiplying
// the upload ceiling. Protocol messages are not counted as payload uploads.
func SetUploadLimit(bytes int64) {
	if bytes <= 0 {
		uploadLimiter.SetLimit(rate.Inf)
	} else {
		uploadLimiter.SetLimit(rate.Limit(bytes))
	}
}

type SavedPeer struct {
	Hash      string   `json:"hash"`
	Until     int64    `json:"until"`
	Addresses []string `json:"addresses"`
}
type SavedNode struct {
	ID      string `json:"id"`
	Address string `json:"address"`
}
type Discovery struct {
	Version   int         `json:"version"`
	SavedAt   int64       `json:"savedAt"`
	NodeUntil int64       `json:"nodeUntil,omitempty"`
	Peers     []SavedPeer `json:"peers"`
	Nodes     []SavedNode `json:"nodes"`
}

var nodeCache struct {
	sync.Mutex
	nodes []SavedNode
	until time.Time
}

func validAddress(value string) (netip.AddrPort, bool) {
	addr, err := netip.ParseAddrPort(value)
	return addr, err == nil && addr.Port() != 0 && !addr.Addr().IsUnspecified() && !addr.Addr().IsMulticast()
}

func Load(saved Discovery) {
	Clear()
	now := time.Now()
	if saved.Version != 1 || saved.SavedAt > now.Add(5*time.Minute).Unix() || saved.SavedAt < now.Add(-24*time.Hour).Unix() {
		return
	}
	cache.Lock()
	for _, row := range saved.Peers {
		if len(cache.values) == 32 {
			break
		}
		var hash metainfo.Hash
		raw, err := hex.DecodeString(row.Hash)
		if err != nil || len(raw) != len(hash) || row.Until <= now.Unix() {
			continue
		}
		copy(hash[:], raw)
		memo := peerMemo{until: time.Unix(row.Until, 0)}
		if memo.until.After(now.Add(peerLifetime)) {
			memo.until = now.Add(peerLifetime)
		}
		seen := map[netip.AddrPort]bool{}
		for _, value := range row.Addresses {
			if len(memo.peers) == PeerLimit {
				break
			}
			if addr, ok := validAddress(value); ok && !seen[addr] {
				seen[addr] = true
				memo.peers = append(memo.peers, torrent.PeerInfo{Addr: addr, Source: torrent.PeerSourceDirect})
			}
		}
		if len(memo.peers) != 0 {
			cache.values[hash] = memo
		}
	}
	cache.Unlock()
	nodeCache.Lock()
	nodeCache.nodes = nil
	seen := map[string]bool{}
	for _, row := range saved.Nodes {
		if len(nodeCache.nodes) == 256 {
			break
		}
		id, err := hex.DecodeString(row.ID)
		if _, ok := validAddress(row.Address); !ok || err != nil || len(id) != 20 || seen[row.Address] {
			continue
		}
		seen[row.Address] = true
		nodeCache.nodes = append(nodeCache.nodes, row)
	}
	nodeCache.until = time.Unix(saved.NodeUntil, 0)
	if saved.NodeUntil == 0 {
		nodeCache.until = time.Unix(saved.SavedAt, 0).Add(24 * time.Hour)
	}
	if nodeCache.until.After(now.Add(24 * time.Hour)) {
		nodeCache.until = now.Add(24 * time.Hour)
	}
	if !nodeCache.until.After(now) {
		nodeCache.nodes = nil
	}
	nodeCache.Unlock()
}

func SnapshotDiscovery() Discovery {
	now := time.Now()
	result := Discovery{Version: 1, SavedAt: now.Unix()}
	cache.Lock()
	for hash, memo := range cache.values {
		if !memo.until.After(now) {
			continue
		}
		row := SavedPeer{Hash: hash.String(), Until: memo.until.Unix()}
		for _, peer := range memo.peers {
			row.Addresses = append(row.Addresses, peer.Addr.String())
		}
		result.Peers = append(result.Peers, row)
	}
	cache.Unlock()
	nodeCache.Lock()
	if nodeCache.until.After(now) {
		result.Nodes = append([]SavedNode(nil), nodeCache.nodes...)
		result.NodeUntil = nodeCache.until.Unix()
	}
	nodeCache.Unlock()
	return result
}

func RememberDHT(client *torrent.Client) {
	if client == nil {
		return
	}
	rows := []SavedNode{}
	seen := map[string]bool{}
	for _, server := range client.DhtServers() {
		provider, ok := server.(interface{ Nodes() []krpc.NodeInfo })
		if !ok {
			continue
		}
		for _, node := range provider.Nodes() {
			address := node.Addr.String()
			if _, ok := validAddress(address); !ok || seen[address] {
				continue
			}
			seen[address] = true
			rows = append(rows, SavedNode{ID: hex.EncodeToString(node.ID[:]), Address: address})
			if len(rows) == 256 {
				break
			}
		}
		if len(rows) == 256 {
			break
		}
	}
	if len(rows) != 0 {
		nodeCache.Lock()
		nodeCache.nodes, nodeCache.until = rows, time.Now().Add(24*time.Hour)
		nodeCache.Unlock()
	}
}

func configureDHT(cfg *torrent.ClientConfig) {
	original := cfg.DhtStartingNodes
	cfg.DhtStartingNodes = func(network string) dht.StartingNodesGetter {
		return func() ([]dht.Addr, error) {
			cached := []dht.Addr{}
			nodeCache.Lock()
			if nodeCache.until.After(time.Now()) {
				for _, row := range nodeCache.nodes {
					addr, ok := validAddress(row.Address)
					if !ok || network == "udp4" && !addr.Addr().Is4() || network == "udp6" && addr.Addr().Is4() {
						continue
					}
					cached = append(cached, dht.NewAddr(net.UDPAddrFromAddrPort(addr)))
				}
			}
			nodeCache.Unlock()
			var bootstrap []dht.Addr
			var err error
			if original != nil {
				bootstrap, err = original(network)()
			} else {
				bootstrap, err = dht.GlobalBootstrapAddrs(network)
			}
			if len(cached) != 0 {
				return append(cached, bootstrap...), nil
			}
			return bootstrap, err
		}
	}
}
