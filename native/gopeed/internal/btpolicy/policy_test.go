package btpolicy

import (
	"bytes"
	"net/netip"
	"testing"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

func policyTorrent(t *testing.T, private bool) *torrent.Torrent {
	t.Helper()
	cfg := torrent.NewDefaultClientConfig()
	Configure(cfg)
	cfg.DataDir, cfg.ListenPort = t.TempDir(), 0
	cfg.ListenHost = func(string) string { return "127.0.0.1" }
	cfg.NoDHT, cfg.DisableTrackers, cfg.DisableUTP, cfg.DisableIPv6 = true, true, true, true
	disk := storage.NewFileWithCompletion(cfg.DataDir, storage.NewMapPieceCompletion())
	cfg.DefaultStorage = disk
	cl, err := torrent.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cl.Close(); disk.Close(); Clear() })
	info := metainfo.Info{Name: "fixture.bin", PieceLength: 16384, Length: 16384,
		Pieces: bytes.Repeat([]byte{1}, 20), Private: &private}
	tor, err := cl.AddTorrent(&metainfo.MetaInfo{InfoBytes: bencode.MustMarshal(info)})
	if err != nil {
		t.Fatal(err)
	}
	return tor
}

func TestPublicDiscoveryDoesNotExpandPrivateTrackers(t *testing.T) {
	private := policyTorrent(t, true)
	AddPublicTrackers(private)
	if len(private.Metainfo().AnnounceList) != 0 {
		t.Fatal("private torrent gained public trackers")
	}
	public := policyTorrent(t, false)
	AddPublicTrackers(public)
	if len(public.Metainfo().AnnounceList) < 4 {
		t.Fatal("public torrent did not gain fallback discovery")
	}
}

func TestExpiredPeerMemoIsNotReused(t *testing.T) {
	tor := policyTorrent(t, true)
	cache.Lock()
	cache.values[tor.InfoHash()] = peerMemo{until: time.Now().Add(-time.Second),
		peers: []torrent.PeerInfo{{Addr: netip.MustParseAddrPort("127.0.0.1:1")}}}
	cache.Unlock()
	Restore(tor)
	cache.Lock()
	_, exists := cache.values[tor.InfoHash()]
	cache.Unlock()
	if exists || tor.Stats().TotalPeers != 0 {
		t.Fatal("expired peer discovery was reused")
	}
}
