package bt

import (
	"bytes"
	"encoding/base64"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/internal/controller"
	"github.com/GopeedLab/gopeed/pkg/base"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

func TestWarmSessionExpiresAndCannotHoldOutputOpen(t *testing.T) {
	SetAsterLinkCache(t.TempDir())
	defer closeClient()
	prior := warmSessionLifetime
	warmSessionLifetime = 50 * time.Millisecond
	defer func() { warmSessionLifetime = prior }()
	dir := t.TempDir()
	data := bytes.Repeat([]byte("verified idle torrent\n"), 1000)
	path := filepath.Join(dir, "warm.bin")
	os.WriteFile(path, data, 0600)
	private := true
	info := metainfo.Info{PieceLength: 16384, Private: &private}
	if err := info.BuildFromFilePath(path); err != nil {
		t.Fatal(err)
	}
	mi := metainfo.MetaInfo{InfoBytes: bencode.MustMarshal(info)}
	var encoded bytes.Buffer
	mi.Write(&encoded)
	f := &Fetcher{}
	ctl := controller.NewController()
	ctl.GetConfig = func(target any) { *target.(**config) = &config{ListenPort: 0} }
	f.Setup(ctl)
	req := &base.Request{URL: "data:application/x-bittorrent;base64," + base64.StdEncoding.EncodeToString(encoded.Bytes()), Labels: map[string]string{sessionPathLabel: dir}}
	if err := f.Resolve(req); err != nil {
		t.Fatal(err)
	}
	if err := f.Create(&base.Options{Path: dir, SelectFiles: []int{0}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	f.torrent.VerifyData()
	if !f.isDone() {
		t.Fatal("fixture failed verification")
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path, path+".saved"); err != nil {
		t.Fatal("output remained open", err)
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		lock.Lock()
		closed := client == nil
		lock.Unlock()
		if closed {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("idle torrent client did not close")
}

func TestWarmSessionStorageRejectsLateIOAndResetsCompletion(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "old.bin")
	want := []byte("completed file")
	if err := os.WriteFile(path, want, 0600); err != nil {
		t.Fatal(err)
	}
	ft := &fileTorrentImpl{files: []file{{rawPath: "old.bin", path: path, length: int64(len(want))}},
		completion: storage.NewMapPieceCompletion()}
	key := metainfo.PieceKey{InfoHash: ft.infoHash, Index: 0}
	ft.completion.Set(key, true)
	ft.freeze()
	readerWriter := fileTorrentImplIO{ft}
	if n, err := readerWriter.WriteAt([]byte("late"), 0); n != 0 || err != errFrozen {
		t.Fatalf("late peer write reached exported file: %d %v", n, err)
	}
	if n, err := readerWriter.ReadAt(make([]byte, len(want)), 0); n != 0 || err != io.EOF {
		t.Fatalf("upload read exported file: %d %v", n, err)
	}
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatal("released output changed", err)
	}
	ft.resetForSession(t.TempDir())
	completed, err := ft.completion.Get(key)
	if err != nil || completed.Complete {
		t.Fatal("a new output inherited another task's completed pieces", err)
	}
}
