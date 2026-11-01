package bt

import (
	"sync/atomic"
	"testing"

	"github.com/GopeedLab/gopeed/internal/fetcher"
	"github.com/GopeedLab/gopeed/pkg/base"
)

func TestTransferBytesExcludeCachedProgressAndOtherSelectedFiles(t *testing.T) {
	storage := &fileTorrentImpl{received: make([]atomic.Int64, 3)}
	storage.received[0].Store(100)
	storage.received[1].Store(200)
	first := &Fetcher{meta: &fetcher.FetcherMeta{Opts: &base.Options{SelectFiles: []int{0}}}}
	second := &Fetcher{meta: &fetcher.FetcherMeta{Opts: &base.Options{SelectFiles: []int{1}}}}
	first.transferStorage.Store(storage)
	second.transferStorage.Store(storage)
	if first.DownloadedBytes() != 100 || second.DownloadedBytes() != 200 {
		t.Fatal("per-file tasks counted the entire torrent's traffic")
	}
	// Cache verification performs reads, without changing payload writes.
	storage.received[0].Add(50)
	if first.DownloadedBytes()+second.DownloadedBytes() != 350 {
		t.Fatal("aggregate speed double-counted traffic from another selected file")
	}
	first.transferBase.Store(first.receivedFrom(storage))
	if first.DownloadedBytes() != 0 {
		t.Fatal("a resumed task included earlier network writes")
	}
	storage.received[0].Add(10)
	if first.DownloadedBytes() != 10 {
		t.Fatal("resume did not count only new bytes")
	}
}
