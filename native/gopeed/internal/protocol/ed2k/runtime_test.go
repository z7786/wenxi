package ed2k

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/engine"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/fetcher"
	"github.com/GopeedLab/gopeed/pkg/base"
)

type memoryStorage struct {
	sync.Mutex
	raw []byte
}

func (m *memoryStorage) Get(_, _ string, out any) (bool, error) {
	m.Lock()
	defer m.Unlock()
	if len(m.raw) == 0 {
		return false, nil
	}
	return true, json.Unmarshal(m.raw, out)
}
func (m *memoryStorage) Put(_, _ string, value any) error {
	m.Lock()
	defer m.Unlock()
	var err error
	m.raw, err = json.Marshal(value)
	return err
}

type seedEvents struct {
	ready chan engine.Progress
	ended chan *engine.Error
}

func (s *seedEvents) SetProgress(_ engine.RunID, p engine.Progress) {
	select {
	case s.ready <- p:
	default:
	}
}
func (s *seedEvents) SendEnded(_ engine.RunID, e *engine.Error) { s.ended <- e }
func (*seedEvents) SetNetwork(engine.Network)                   {}

func seed(t *testing.T, data []byte) (string, int) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	folder := t.TempDir()
	path := filepath.Join(folder, "source.bin")
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	var hasher piece.FileHasher
	hasher.Write(data)
	url := fmt.Sprintf("ed2k://|file|source.bin|%d|%s|/", len(data), hasher.FileHash())
	events := &seedEvents{ready: make(chan engine.Progress, 200), ended: make(chan *engine.Error, 2)}
	core, err := engine.Start(engine.Config{Version: "AsterLink test", Port: port, DataFolder: filepath.Join(folder, "state")}, events)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := core.Close(); err != nil {
			t.Error(err)
		}
	})
	core.Post(engine.RunCommand{ID: 1, Mode: engine.ModeSeed, Link: url, File: path})
	timeout := time.After(10 * time.Second)
	for {
		select {
		case p := <-events.ready:
			if p.Received == int64(len(data)) {
				return url, port
			}
		case err := <-events.ended:
			t.Fatalf("seed ended: %v", err)
		case <-timeout:
			t.Fatal("seed never verified")
		}
	}
}
func newTestFetcher(t *testing.T, runtime *Runtime, url, path string, limit int64) *Fetcher {
	t.Helper()
	f := &Fetcher{runtime: runtime, meta: &fetcher.FetcherMeta{}}
	f.Setup(nil)
	if err := f.Resolve(&base.Request{URL: url}); err != nil {
		t.Fatal(err)
	}
	if err := f.Create(&base.Options{Name: filepath.Base(path), Path: filepath.Dir(path), Extra: &Options{SpeedLimit: limit}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Pause() })
	return f
}
func waitFor(t *testing.T, f *Fetcher, condition func(engine.Progress) bool) engine.Progress {
	t.Helper()
	end := time.Now().Add(35 * time.Second)
	for time.Now().Before(end) {
		p := f.Stats().(engine.Progress)
		if condition(p) {
			return p
		}
		select {
		case err := <-f.done:
			t.Fatalf("transfer ended early: %v, progress %+v", err, p)
		default:
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("transfer timeout, progress: %+v", f.Stats())
	return engine.Progress{}
}
func TestLocalED2KResumeAcrossEngineRestart(t *testing.T) {
	data := make([]byte, piece.PartSize+2*piece.BlockSize+17)
	for i := range data {
		data[i] = byte((i*31 + i/97) % 251)
	}
	url, port := seed(t, data)
	url += fmt.Sprintf("|sources,127.0.0.1:%d|/", port)
	storage := &memoryStorage{}
	folder := t.TempDir()
	target := filepath.Join(folder, "payload.gopeed")
	runtime := NewRuntime(filepath.Join(folder, "engine"), storage)
	runtime.servers = nil
	runtime.settings = engine.Settings{}
	f := newTestFetcher(t, runtime, url, target, 512*1024)
	waitFor(t, f, func(p engine.Progress) bool { return p.Received >= piece.BlockSize })
	if err := f.Pause(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	after, _ := os.ReadFile(target)
	if !bytes.Equal(before, after) {
		t.Fatal("writer continued after Pause")
	}
	if err = f.Pause(); err != nil {
		t.Fatal("repeated pause:", err)
	}
	state, err := runtime.load()
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Transfers) != 1 {
		t.Fatalf("missing resume state: %+v", state)
	}
	for _, transfer := range state.Transfers {
		if len(transfer.WrittenBlocks) == 0 && transfer.VerifiedParts.Count() == 0 {
			t.Fatal("checkpoint lost received blocks")
		}
	}
	runtime = NewRuntime(filepath.Join(folder, "engine"), storage)
	runtime.servers = nil
	runtime.settings = engine.Settings{}
	resumed := newTestFetcher(t, runtime, url, target, 0)
	select {
	case err := <-resumed.done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(35 * time.Second):
		t.Fatalf("resume timeout: %+v", resumed.Stats())
	}
	if err = resumed.Pause(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(target)
	if err != nil || !bytes.Equal(data, got) {
		t.Fatalf("ED2K payload mismatch: %v", err)
	}
	if resumed.Progress().TotalDownloaded() != int64(len(data)) {
		t.Fatal("wrong completion progress")
	}
	state, err = runtime.load()
	if err != nil {
		t.Fatal(err)
	}
	for hash, transfer := range state.Transfers {
		if !transfer.VerifiedParts.IsFull() {
			t.Fatal("completed without MD4 verification")
		}
		if err = runtime.Forget(hash.String(), target); err != nil {
			t.Fatal(err)
		}
	}
	state, _ = runtime.load()
	if len(state.Transfers) != 0 {
		t.Fatal("deleted transfer can be resurrected")
	}
	if err = os.Remove(target); err != nil {
		t.Fatal("output handle leaked:", err)
	}
}

func TestLockedFileRejectsWritesAfterClose(t *testing.T) {
	path := filepath.Join(t.TempDir(), "output")
	raw, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f := &lockedFile{file: raw}
	if _, err = f.WriteAt([]byte("ok"), 0); err != nil {
		t.Fatal(err)
	}
	if err = f.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = f.WriteAt([]byte("bad"), 0); err == nil {
		t.Fatal("write after close accepted")
	}
	if err = f.Close(); err != nil {
		t.Fatal(err)
	}
}

// The upstream uses hash-keyed maps that need its versioned codec.
func TestEmbeddedStateRoundTrip(t *testing.T) {
	state, err := store.Decode(nil)
	if err != nil {
		t.Fatal(err)
	}
	var h piece.FileHasher
	h.Write([]byte("state"))
	hash := h.FileHash()
	state.Transfers[hash] = store.Transfer{Size: 5, File: "payload", WrittenBlocks: []piece.Block{{Begin: 0, End: 3}}}
	raw, err := store.Encode(state)
	if err != nil {
		t.Fatal(err)
	}
	got, err := store.Decode(raw)
	if err != nil || got.Transfers[hash].WrittenBlocks[0].End != 3 {
		t.Fatal("state round trip failed:", err)
	}
}

func TestSpeedCountsNetworkBytesInsteadOfRestoredProgress(t *testing.T) {
	f := &Fetcher{}
	f.setProgress(engine.Progress{Received: 10000})
	if f.DownloadedBytes() != 0 {
		t.Fatal("restored bytes counted as download speed")
	}
	f.setProgress(engine.Progress{Received: 12000, NetworkReceived: 2000})
	f.setProgress(engine.Progress{Received: 10000, NetworkReceived: 2200})
	if f.DownloadedBytes() != 2200 {
		t.Fatal("network byte counter follows disk progress")
	}
}

func TestRemovingOldHistoryKeepsNewFileCheckpoint(t *testing.T) {
	r := NewRuntime(t.TempDir(), &memoryStorage{})
	state, _ := r.load()
	var h piece.FileHasher
	h.Write([]byte("same content"))
	hash := h.FileHash()
	state.Transfers[hash] = store.Transfer{Size: 12, File: "new-payload"}
	if err := r.save(state); err != nil {
		t.Fatal(err)
	}
	if err := r.Forget(hash.String(), "old-payload"); err != nil {
		t.Fatal(err)
	}
	state, _ = r.load()
	if len(state.Transfers) != 1 {
		t.Fatal("old history deleted another task's checkpoint")
	}
}
