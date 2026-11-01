// Package btpolicy shares bounded peer discovery between metadata, downloads,
// and streaming. Discovery snapshots are bounded and encrypted by the caller.
package btpolicy

import (
	"context"
	"net/netip"
	"sync"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
)

const PeerLimit = 80
const peerLifetime = 6 * time.Hour

var publicTrackers = [][]string{
	{"udp://tracker.opentrackr.org:1337/announce"},
	{"udp://open.stealth.si:80/announce"},
	{"udp://tracker.torrent.eu.org:451/announce"},
	{"https://tracker.gbitt.info/announce"},
	{"udp://exodus.desync.com:6969/announce"},
	{"udp://tracker.dler.org:6969/announce"},
	{"udp://opentracker.i2p.rocks:6969/announce"},
	{"udp://open.demonii.com:1337/announce"},
	{"udp://tracker.moeking.me:6969/announce"},
	{"udp://tracker.openbittorrent.com:6969/announce"},
	{"udp://explodie.org:6969/announce"},
	{"udp://tracker.bittor.pw:1337/announce"},
	{"udp://tracker1.bt.moack.co.kr:80/announce"},
	{"udp://tracker-udp.gbitt.info:80/announce"},
	{"https://tracker.tamersunion.org:443/announce"},
	{"https://tracker.lilithraws.org:443/announce"},
	{"https://tr.burnabyhighstar.com:443/announce"},
	{"https://tracker2.ctix.cn:443/announce"},
	{"http://tracker.openbittorrent.com:80/announce"},
	{"http://open.acgnxtracker.com:80/announce"},
}

type peerMemo struct {
	peers []torrent.PeerInfo
	until time.Time
}

var cache = struct {
	sync.Mutex
	values map[metainfo.Hash]peerMemo
}{values: make(map[metainfo.Hash]peerMemo)}

func Configure(cfg *torrent.ClientConfig) {
	cfg.EstablishedConnsPerTorrent = PeerLimit
	cfg.HalfOpenConnsPerTorrent = 24
	cfg.TotalHalfOpenConns = 48
	// Keep the library's TCP/uTP, DHT, PEX and encryption negotiation defaults.
	// WebTorrent is a browser transport; native peers and webseeds remain enabled.
	cfg.DisableWebtorrent = true
	cfg.Seed = false
	cfg.UploadRateLimiter = uploadLimiter
	configureDHT(cfg)
}

func Restore(t *torrent.Torrent) {
	cache.Lock()
	item, ok := cache.values[t.InfoHash()]
	if ok && time.Now().After(item.until) {
		delete(cache.values, t.InfoHash())
		ok = false
	}
	cache.Unlock()
	if ok {
		t.AddPeers(item.peers)
	}
}

func AddPublicTrackers(t *torrent.Torrent) {
	info := t.Info()
	// Metadata must establish that this is public before expanding discovery.
	if info != nil && (info.Private == nil || !*info.Private) {
		// Keep the original four fallback trackers immediately available. Probe
		// the additional set in the background with four bounded workers.
		t.AddTrackers(publicTrackers[:4])
		go func() {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go func() {
				select {
				case <-t.Closed():
					cancel()
				case <-ctx.Done():
				}
			}()
			jobs := make(chan string)
			var workers sync.WaitGroup
			for i := 0; i < 4; i++ {
				workers.Add(1)
				go func() {
					defer workers.Done()
					for address := range jobs {
						probe, done := context.WithTimeout(ctx, 5*time.Second)
						ok := trackerAvailable(probe, address)
						done()
						if ok && ctx.Err() == nil {
							t.AddTrackers([][]string{{address}})
						}
					}
				}()
			}
			for _, tier := range publicTrackers[4:] {
				select {
				case jobs <- tier[0]:
				case <-ctx.Done():
					close(jobs)
					workers.Wait()
					return
				}
			}
			close(jobs)
			workers.Wait()
		}()
	}
}

func Remember(t *torrent.Torrent) {
	if t == nil {
		return
	}
	peers := make([]torrent.PeerInfo, 0, PeerLimit)
	seen := map[netip.AddrPort]bool{}
	// The pinned library's KnownSwarm reads pending maps without a lock. Use
	// PeerConns' locked snapshot and immutable outgoing remote addresses instead.
	for _, conn := range t.PeerConns() {
		if conn.Discovery == torrent.PeerSourceIncoming || conn.RemoteAddr == nil {
			continue
		}
		addr, err := netip.ParseAddrPort(conn.RemoteAddr.String())
		if err != nil || addr.Port() == 0 || seen[addr] {
			continue
		}
		seen[addr] = true
		peers = append(peers, torrent.PeerInfo{Addr: addr, Source: torrent.PeerSourceDirect})
		if len(peers) == PeerLimit {
			break
		}
	}
	if len(peers) == 0 {
		return
	}
	now := time.Now()
	cache.Lock()
	defer cache.Unlock()
	for hash, item := range cache.values {
		if !item.until.After(now) {
			delete(cache.values, hash)
		}
	}
	if len(cache.values) >= 32 {
		var oldest metainfo.Hash
		deadline := now.Add(2 * peerLifetime)
		for hash, item := range cache.values {
			if item.until.Before(deadline) {
				oldest, deadline = hash, item.until
			}
		}
		delete(cache.values, oldest)
	}
	cache.values[t.InfoHash()] = peerMemo{peers: peers, until: now.Add(peerLifetime)}
}

func Clear() {
	cache.Lock()
	cache.values = make(map[metainfo.Hash]peerMemo)
	cache.Unlock()
	nodeCache.Lock()
	nodeCache.nodes, nodeCache.until = nil, time.Time{}
	nodeCache.Unlock()
	trackerCache.Lock()
	trackerCache.rows = map[string]trackerHealth{}
	trackerCache.Unlock()
}
