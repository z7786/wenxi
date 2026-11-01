package btpolicy

import (
	"context"
	"encoding/binary"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anacrolix/dht/v2"
	"github.com/anacrolix/torrent"
	"golang.org/x/time/rate"
)

func TestDiscoveryRoundTripExpiresAndBootstraps(t *testing.T) {
	t.Cleanup(Clear)
	hash := strings.Repeat("ab", 20)
	Load(Discovery{Version: 1, SavedAt: time.Now().Unix(),
		Peers: []SavedPeer{{Hash: hash, Until: time.Now().Add(time.Hour).Unix(), Addresses: []string{"127.0.0.1:12", "127.0.0.1:12", "0.0.0.0:1", "bad"}}},
		Nodes: []SavedNode{{ID: hash, Address: "127.0.0.1:13"}, {ID: hash, Address: "[::1]:14"}}})
	saved := SnapshotDiscovery()
	if len(saved.Peers) != 1 || len(saved.Peers[0].Addresses) != 1 || len(saved.Nodes) != 2 {
		t.Fatalf("invalid discovery: %+v", saved)
	}
	cfg := torrent.NewDefaultClientConfig()
	cfg.DhtStartingNodes = func(string) dht.StartingNodesGetter {
		return func() ([]dht.Addr, error) {
			return []dht.Addr{dht.NewAddr(&net.UDPAddr{IP: net.ParseIP("127.0.0.2"), Port: 15})}, nil
		}
	}
	Configure(cfg)
	nodes, err := cfg.DhtStartingNodes("udp4")()
	if err != nil || len(nodes) != 2 {
		t.Fatalf("cached nodes lost fallback: %v %v", nodes, err)
	}
	saved.SavedAt = time.Now().Add(-25 * time.Hour).Unix()
	Load(saved)
	if got := SnapshotDiscovery(); len(got.Peers) != 0 || len(got.Nodes) != 0 {
		t.Fatal("stale discovery reused")
	}
	SetUploadLimit(65536)
	if uploadLimiter.Limit() != rate.Limit(65536) {
		t.Fatal("upload ceiling not applied")
	}
	SetUploadLimit(0)
	if uploadLimiter.Limit() != rate.Inf {
		t.Fatal("explicit unlimited ignored")
	}
	SetUploadLimit(DefaultUploadLimit)
}

func TestTrackerHealthValidatesProtocolAndCoolsFailures(t *testing.T) {
	t.Cleanup(Clear)
	server, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go func() {
		request := make([]byte, 100)
		n, addr, err := server.ReadFrom(request)
		if err != nil || n != 16 || binary.BigEndian.Uint64(request) != 0x41727101980 {
			return
		}
		response := make([]byte, 16)
		copy(response[4:8], request[12:16])
		binary.BigEndian.PutUint64(response[8:], 123)
		server.WriteTo(response, addr)
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if !trackerAvailable(ctx, "udp://"+server.LocalAddr().String()+"/announce") {
		t.Fatal("valid UDP connect rejected")
	}
	var calls atomic.Int32
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Write([]byte("<html>wrong service</html>"))
	}))
	defer httpServer.Close()
	for i := 0; i < 2; i++ {
		if trackerAvailable(ctx, httpServer.URL+"/announce") {
			t.Fatal("HTML became a tracker")
		}
	}
	if calls.Load() != 1 {
		t.Fatal("failed tracker was probed again during cooldown")
	}
}

func TestDiscoverySavingDoesNotRenewUncontactedDHTNodes(t *testing.T) {
	t.Cleanup(Clear)
	expires := time.Now().Add(5 * time.Minute).Unix()
	Load(Discovery{Version: 1, SavedAt: time.Now().Add(-time.Hour).Unix(), NodeUntil: expires,
		Nodes: []SavedNode{{ID: strings.Repeat("ab", 20), Address: "127.0.0.1:13"}}})
	saved := SnapshotDiscovery()
	if saved.NodeUntil != expires || len(saved.Nodes) != 1 {
		t.Fatalf("saving extended node expiry: %+v", saved)
	}
	Load(saved)
	if got := SnapshotDiscovery(); got.NodeUntil != expires {
		t.Fatalf("restart renewed stale bootstrap: %+v", got)
	}
	saved.NodeUntil = time.Now().Add(-time.Second).Unix()
	Load(saved)
	if len(SnapshotDiscovery().Nodes) != 0 {
		t.Fatal("expired nodes restored despite a recent save")
	}
}
