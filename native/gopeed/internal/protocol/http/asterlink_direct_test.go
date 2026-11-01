package http

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestBaiduDirectDynamicHostBoundedRangesAndRetry(t *testing.T) {
	data := bytes.Repeat([]byte("direct-original-bytes"), 128*1024)
	var active, peak, windows atomic.Int32
	var failed atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != "private-route.invalid" || r.Header.Get("Cookie") != "" || r.UserAgent() != "netdisk" {
			w.WriteHeader(403)
			return
		}
		var first, last int64
		if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &first, &last); err != nil || first < 0 || last < first || last >= int64(len(data)) || last-first+1 > minRangeSize {
			w.WriteHeader(416)
			return
		}
		n := active.Add(1)
		defer active.Add(-1)
		for old := peak.Load(); n > old && !peak.CompareAndSwap(old, n); old = peak.Load() {
		}
		if last-first > 0 {
			windows.Add(1)
			time.Sleep(5 * time.Millisecond)
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, len(data)))
		w.Header().Set("Content-Length", fmt.Sprint(last-first+1))
		w.WriteHeader(206)
		if last-first > 1024 && failed.CompareAndSwap(false, true) {
			_, _ = w.Write(data[first : first+1024])
			return
		}
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL, Extra: &fhttp.ReqExtra{Header: map[string]string{"Host": "private-route.invalid", "User-Agent": "netdisk"}}}); err != nil {
		t.Fatal(err)
	}
	retries := 1
	if err := f.Create(&base.Options{Name: "original.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: 64, ConnectionProfile: "baidu_direct", RetryLimit: &retries}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	if err := f.Wait(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(f.Meta().SingleFilepath())
	if err != nil || !bytes.Equal(got, data) || windows.Load() < 8 || !failed.Load() || peak.Load() > 8 || peak.Load() < 2 {
		t.Fatalf("download integrity/policy: err=%v windows=%d peak=%d retried=%t", err, windows.Load(), peak.Load(), failed.Load())
	}
}
