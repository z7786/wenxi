package http

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

// A nearly complete file can still have a sub-MiB range whose connection is
// throttled. Fast workers must stay available after their own ranges finish.
func TestSlowDownloadTailKeepsIdleWorkers(t *testing.T) {
	for _, profile := range []string{"uc", "quark_route_1", "baidu_public", ""} {
		t.Run(profile, func(t *testing.T) {
			const chunkSize = 768 * 1024
			data := make([]byte, 4*chunkSize)
			for i := range data {
				data[i] = byte((i*31 + i/257) % 251)
			}
			prefixSent := make(chan struct{})
			helpArrived := make(chan struct{})
			var once sync.Once
			var helped atomic.Bool
			var active, peak atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				first, last, ok := xunleiRange(t, r, len(data))
				if !ok {
					w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
					return
				}
				if first != 0 || last != 0 {
					n := active.Add(1)
					defer active.Add(-1)
					for previous := peak.Load(); n > previous && !peak.CompareAndSwap(previous, n); previous = peak.Load() {
					}
				}
				xunleiResponse(w, first, last, len(data))
				w.(http.Flusher).Flush()
				if first == 0 && last == chunkSize-1 {
					_, _ = w.Write(data[:16*1024])
					w.(http.Flusher).Flush()
					close(prefixSent)
					select {
					case <-helpArrived:
						helped.Store(true)
					case <-time.After(3 * time.Second):
					case <-r.Context().Done():
						return
					}
					_, _ = w.Write(data[16*1024 : last+1])
					return
				}
				if first > 0 && first < chunkSize && last < chunkSize {
					once.Do(func() { close(helpArrived) })
				}
				if first >= chunkSize {
					select {
					case <-prefixSent:
					case <-r.Context().Done():
						return
					}
				}
				_, _ = w.Write(data[first : last+1])
			}))
			defer server.Close()
			f := buildFetcher()
			defer f.Close()
			if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
				t.Fatal(err)
			}
			if err := f.Create(&base.Options{Name: "limited-tail.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: 4, ConnectionProfile: profile}}); err != nil {
				t.Fatal(err)
			}
			if err := f.Start(); err != nil {
				t.Fatal(err)
			}
			verifyXunleiDownload(t, f, data)
			if !helped.Load() {
				t.Fatal("idle workers retired while the slow connection still owned a sub-MiB tail")
			}
			if peak.Load() > 4 {
				t.Fatalf("tail helpers exceeded the configured connection limit: %d", peak.Load())
			}
		})
	}
}

func TestSlowTailPauseAndRestore(t *testing.T) {
	const chunkSize = 768 * 1024
	data := bytes.Repeat([]byte("slow-tail-0123456"), 4*chunkSize/16)
	handoff := make(chan struct{})
	var once sync.Once
	var finish atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		xunleiResponse(w, first, last, len(data))
		w.(http.Flusher).Flush()
		if !finish.Load() && first < chunkSize && last > 0 {
			if first == 0 {
				_, _ = w.Write(data[:16*1024])
				w.(http.Flusher).Flush()
			} else {
				once.Do(func() { close(handoff) })
			}
			<-r.Context().Done()
			return
		}
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	if err := f.Create(&base.Options{Name: "tail-resume.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: 4, ConnectionProfile: "uc"}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-handoff:
	case <-time.After(4 * time.Second):
		t.Fatal("slow range was not divided before pause")
	}
	paused := time.Now()
	if err := f.Pause(); err != nil {
		t.Fatal(err)
	}
	if time.Since(paused) > time.Second {
		t.Fatal("idle helper wait delayed pausing")
	}
	if active, _ := f.ConnectionCounts(); active != 0 {
		t.Fatal("paused task retained active requests")
	}
	manager := &FetcherManager{}
	checkpoint, err := manager.Store(f)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(checkpoint)
	if err != nil {
		t.Fatal(err)
	}
	value, restore := manager.Restore()
	if err := json.Unmarshal(raw, value); err != nil {
		t.Fatal(err)
	}
	resumed := restore(f.Meta(), value).(*Fetcher)
	resumed.Setup(f.ctl)
	defer resumed.Close()
	if got := resumed.Progress()[0]; got != f.Progress()[0] {
		t.Fatalf("saved progress changed during restore: %d", got)
	}
	finish.Store(true)
	if err := resumed.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, resumed, data)
}

func TestIdleTailHelpersFinishOnTerminalError(t *testing.T) {
	const chunkSize = 256 * 1024
	data := bytes.Repeat([]byte("failed-tail-0123"), 4*chunkSize/16)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		xunleiResponse(w, first, last, len(data))
		w.(http.Flusher).Flush()
		if first == 0 && last == chunkSize-1 {
			_, _ = w.Write(data[:8192])
			w.(http.Flusher).Flush()
			time.Sleep(100 * time.Millisecond)
			return // Truncated body with no retry budget.
		}
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	retries := 0
	if err := f.Create(&base.Options{Name: "failed-tail.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: 4, RetryLimit: &retries}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() { finished <- f.Wait() }()
	select {
	case err := <-finished:
		if !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("terminal request error changed to %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("idle helpers waited forever for a failed worker")
	}
}

func TestTailSpeedDecision(t *testing.T) {
	now := time.Now()
	for _, scenario := range []struct {
		name                   string
		elapsed                time.Duration
		transferred, remaining int64
		want                   bool
	}{
		{"warmup", 100 * time.Millisecond, 0, 768 * 1024, false},
		{"slow", time.Second, 8 * 1024, 768 * 1024, true},
		{"fast", time.Second, 4 * 1024 * 1024, 768 * 1024, false},
		{"fast-final-seconds", time.Second, 256 * 1024, 512 * 1024, false},
		{"minimum-range", time.Second, 1, 2*tailMinRangeSize - 1, false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			var sample tailSample
			sample.start(now)
			sample.progress(scenario.transferred, now.Add(scenario.elapsed))
			if got := sample.slow(scenario.remaining, now.Add(scenario.elapsed)); got != scenario.want {
				t.Fatalf("tail split decision=%v, want=%v", got, scenario.want)
			}
		})
	}
	var sample tailSample
	sample.start(now)
	sample.progress(4*1024*1024, now.Add(time.Second))
	if !sample.slow(512*1024, now.Add(3*time.Second)) {
		t.Fatal("an old fast sample hid a stalled tail")
	}
	sample.start(now.Add(4 * time.Second))
	if sample.slow(512*1024, now.Add(4*time.Second)) {
		t.Fatal("a new request inherited the previous request's slow measurement")
	}
}

func TestFastDownloadTailDoesNotAddRequests(t *testing.T) {
	const workers = 64
	data := bytes.Repeat([]byte("fast-tail-data-0123456789"), 64*1024)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if first != 0 || last != 0 {
			requests.Add(1)
		}
		xunleiResponse(w, first, last, len(data))
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	if err := f.Create(&base.Options{Name: "fast-tail.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: workers, ConnectionProfile: "quark_route_1"}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, f, data)
	if _, total := f.ConnectionCounts(); requests.Load() != int32(total) {
		t.Fatalf("fast download made %d requests for %d initial ranges", requests.Load(), total)
	}
}

// Resume the final 768 KiB of a 100 MiB file. The endpoint meters every
// connection at 64 KiB/s, including helpers, so late parallelism matters.
func TestLargeDownloadSlowFinalRangeRemainsParallel(t *testing.T) {
	const (
		size      = 100 * 1024 * 1024
		remaining = 768 * 1024
		workers   = 16
		blockSize = 8 * 1024
	)
	data := make([]byte, size)
	for i := range data {
		data[i] = byte((i*17 + i/113) % 251)
	}
	var helped atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		xunleiResponse(w, first, last, len(data))
		w.(http.Flusher).Flush()
		if first == 0 && last == 0 {
			_, _ = w.Write(data[:1])
			return
		}
		if first > size-remaining {
			helped.Store(true)
		}
		for start := first; start <= last; start += blockSize {
			select {
			case <-time.After(125 * time.Millisecond):
			case <-r.Context().Done():
				return
			}
			if _, err := w.Write(data[start:min(start+blockSize, last+1)]); err != nil {
				return
			}
			w.(http.Flusher).Flush()
		}
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	if err := f.Create(&base.Options{Name: "large-final-range.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: workers, ConnectionProfile: "uc"}}); err != nil {
		t.Fatal(err)
	}
	f.connections = f.splitConnection()
	seed := append([]byte(nil), data...)
	for _, connection := range f.connections {
		connection.Chunk.Downloaded = connection.Chunk.remain()
		connection.Downloaded = connection.Chunk.Downloaded
		connection.Completed = true
	}
	last := f.connections[len(f.connections)-1]
	last.Chunk.Downloaded -= remaining
	last.Downloaded -= remaining
	last.Completed = false
	clear(seed[size-remaining:])
	if err := os.WriteFile(f.Meta().SingleFilepath(), seed, 0600); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, f, data)
	if !helped.Load() {
		t.Fatal("completed checkpoint workers did not assist the slow final range")
	}
	// One capped connection needs 12 seconds. Leave ample headroom for CI I/O
	// while still catching the old sequential tail, rather than timing noise.
	if elapsed := time.Since(start); elapsed >= 8*time.Second {
		t.Fatalf("parallel 768 KiB tail took %v at 64 KiB/s per connection", elapsed)
	} else {
		t.Logf("final 768 KiB at 64 KiB/s per connection completed in %v (single connection: 12s)", elapsed)
	}
}
