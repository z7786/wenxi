package gopeed

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/internal/btpolicy"
	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

func TestBTCompletedFilesKeepPeerSessionAndReleaseOldOutput(t *testing.T) {
	_, payload, _ := openTestCore(t)
	root := t.TempDir()
	dir := filepath.Join(root, "collection")
	os.Mkdir(dir, 0700)
	first := bytes.Repeat([]byte("first BT data\n"), 4000)
	second := bytes.Repeat([]byte("second BT data\n"), 20000)
	os.WriteFile(filepath.Join(dir, "a.bin"), first, 0600)
	os.WriteFile(filepath.Join(dir, "b.bin"), second, 0600)
	private := true
	info := metainfo.Info{PieceLength: 16384, Private: &private}
	if err := info.BuildFromFilePath(dir); err != nil {
		t.Fatal(err)
	}
	cfg := torrent.NewDefaultClientConfig()
	cfg.DataDir, cfg.ListenPort = root, 0
	cfg.ListenHost = func(string) string { return "127.0.0.1" }
	cfg.NoDHT, cfg.DisableIPv6, cfg.DisableUTP, cfg.Seed = true, true, true, true
	disk := storage.NewFileWithCompletion(root, storage.NewMapPieceCompletion())
	defer disk.Close()
	cfg.DefaultStorage = disk
	var handshakes atomic.Int32
	cfg.Callbacks.CompletedHandshake = func(*torrent.PeerConn, torrent.InfoHash) { handshakes.Add(1) }
	seeder, err := torrent.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer seeder.Close()
	address := seeder.ListenAddrs()[0].(*net.TCPAddr)
	peer := []byte{127, 0, 0, 1, 0, 0}
	binary.BigEndian.PutUint16(peer[4:], uint16(address.Port))
	tracker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(bencode.MustMarshal(map[string]any{"interval": 1, "peers": string(peer)}))
	}))
	defer tracker.Close()
	mi := metainfo.MetaInfo{InfoBytes: bencode.MustMarshal(info), Announce: tracker.URL}
	tor, err := seeder.AddTorrent(&mi)
	if err != nil {
		t.Fatal(err)
	}
	tor.VerifyData()
	var encoded bytes.Buffer
	mi.Write(&encoded)
	data := torrentPrefix + base64.StdEncoding.EncodeToString(encoded.Bytes())
	beginBTIndex(t, "warm-first", data, 0, 0)
	state := waitState(t, "warm-first", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, first)
	if err = Remove("warm-first"); err != nil {
		t.Fatal(err)
	}
	if err = os.RemoveAll(filepath.Join(payload, "warm-first")); err != nil {
		t.Fatal(err)
	}
	count := handshakes.Load()
	if count < 1 {
		t.Fatal("no real peer connection")
	}
	tracker.Close()
	beginBTIndex(t, "warm-second", data, 1, 64*1024)
	live := waitState(t, "warm-second", func(s snapshot) bool { return s.BT != nil && s.Downloaded > 0 })
	if !live.BT.SessionReused || live.BT.Connected < 1 || live.BT.Seeders < 1 {
		t.Fatalf("session not reused: %+v", live.BT)
	}
	// Removing an already exported history item cannot stop the next file.
	if err = Remove("warm-first"); err != nil {
		t.Fatal(err)
	}
	assertPayload(t, waitState(t, "warm-second", func(s snapshot) bool { return s.Status == "done" }, 20*time.Second), second)
	if handshakes.Load() != count {
		t.Fatalf("peer connection reopened: before %d after %d", count, handshakes.Load())
	}
}

func TestBTDiscoveryPersistsEncryptedAcrossRestart(t *testing.T) {
	state, payload, key := openTestCore(t)
	marker := "127.0.0.1:39124"
	btpolicy.Load(btpolicy.Discovery{Version: 1, SavedAt: time.Now().Unix(), Peers: []btpolicy.SavedPeer{{Hash: "abababababababababababababababababababab", Until: time.Now().Add(time.Hour).Unix(), Addresses: []string{marker}}}})
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(state, "gopeed.db"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(marker)) {
		t.Fatal("peer address saved unencrypted")
	}
	if err = Open(state, payload, key); err != nil {
		t.Fatal(err)
	}
	saved := btpolicy.SnapshotDiscovery()
	data, _ := json.Marshal(saved)
	if !bytes.Contains(data, []byte(marker)) {
		t.Fatal("peer address missing after restart")
	}
}
