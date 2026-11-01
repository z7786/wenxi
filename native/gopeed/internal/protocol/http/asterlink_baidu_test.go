package http

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestBaiduConnectionsAndResumeIntegrity(t *testing.T) {
	for _, profile := range []string{"baidu", "baidu_preview"} {
		for _, resume := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/resume=%t", profile, resume), func(t *testing.T) {
				const limit = 4
				data := bytes.Repeat([]byte("baidu-original-data\n"), 64*1024)
				if profile == "baidu_preview" {
					// Even each legacy checkpoint chunk is larger than one request window.
					data = bytes.Repeat([]byte("baidu-original-data\n"), 2*1024*1024)
				}
				var active, maximum atomic.Int32
				var received atomic.Int64
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					var first, last int
					if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &first, &last); err != nil || first < 0 || last < first || last >= len(data) {
						w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
						return
					}
					if profile == "baidu_preview" && int64(last-first+1) > baiduPreviewRequestSize {
						w.WriteHeader(http.StatusForbidden)
						return
					}
					if resume && (first != 0 || last != 0) {
						for i := 0; i < 4; i++ {
							begin := len(data) * i / 4
							if first < begin+128 && last >= begin {
								t.Errorf("request %d-%d overlaps cached bytes %d-%d", first, last, begin, begin+127)
							}
						}
					}
					w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, len(data)))
					w.Header().Set("Content-Length", fmt.Sprint(last-first+1))
					w.WriteHeader(http.StatusPartialContent)
					w.(http.Flusher).Flush()
					if first != 0 || last != 0 {
						n := active.Add(1)
						defer active.Add(-1)
						for prev := maximum.Load(); n > prev && !maximum.CompareAndSwap(prev, n); prev = maximum.Load() {
						}
						time.Sleep(30 * time.Millisecond)
						received.Add(int64(last - first + 1))
					}
					_, _ = w.Write(data[first : last+1])
				}))
				defer server.Close()
				f := buildFetcher()
				defer f.Close()
				if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
					t.Fatal(err)
				}
				if err := f.Create(&base.Options{Name: "resume.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: limit, ConnectionProfile: profile}}); err != nil {
					t.Fatal(err)
				}
				savedBytes := 0
				if resume {
					// Reproduce a checkpoint from the previous multi-connection version.
					seed := make([]byte, len(data))
					for i := 0; i < 4; i++ {
						begin, end := len(data)*i/4, len(data)*(i+1)/4-1
						copy(seed[begin:begin+128], data[begin:begin+128])
						c := &connection{Chunk: newChunk(int64(begin), int64(end))}
						c.Chunk.Downloaded = 128
						c.Downloaded = 128
						f.connections = append(f.connections, c)
					}
					if err := os.WriteFile(f.Meta().SingleFilepath(), seed, 0600); err != nil {
						t.Fatal(err)
					}
					savedBytes = 4 * 128
				}
				if err := f.Start(); err != nil {
					t.Fatal(err)
				}
				if err := f.Wait(); err != nil {
					t.Fatal(err)
				}
				if maximum.Load() != int32(limit) {
					t.Fatalf("concurrent requests=%d, want %d", maximum.Load(), limit)
				}
				// Tail helpers may cancel an in-flight bounded request after
				// shrinking its chunk. Request sizes include those prefetched bytes.
				if received.Load() < int64(len(data)-savedBytes) || f.Progress().TotalDownloaded() != int64(len(data)) {
					t.Fatalf("requested=%d progress=%d size=%d", received.Load(), f.Progress().TotalDownloaded(), len(data))
				}
				if _, total := f.ConnectionCounts(); total != limit {
					t.Fatalf("reported connection limit=%d, want %d", total, limit)
				}
				got, err := os.ReadFile(f.Meta().SingleFilepath())
				if err != nil || !bytes.Equal(got, data) {
					t.Fatal("download changed file contents")
				}
			})
		}
	}
}

func TestBaiduPreviewWindowErrors(t *testing.T) {
	for _, mode := range []string{"truncated-retry", "truncated-exhausted", "wrong-range"} {
		t.Run(mode, func(t *testing.T) {
			data := bytes.Repeat([]byte("original-baidu-content\n"), 512*1024)
			var failed atomic.Bool
			var resumed atomic.Bool
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var first, last int64
				if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &first, &last); err != nil || first < 0 || last < first || last >= int64(len(data)) {
					w.WriteHeader(416)
					return
				}
				if last-first+1 > baiduPreviewRequestSize {
					w.WriteHeader(403)
					return
				}
				if first == baiduPreviewRequestSize+1024 {
					resumed.Store(true)
				}
				if first == baiduPreviewRequestSize && failed.CompareAndSwap(false, true) {
					if mode == "wrong-range" {
						w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-%d/%d", last-first, len(data)))
					} else {
						w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, len(data)))
					}
					w.WriteHeader(206)
					w.(http.Flusher).Flush()
					// End a chunked response early: do not mistake this EOF for a
					// completed window, even if Content-Length was not supplied.
					_, _ = w.Write(data[first : first+1024])
					return
				}
				w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, len(data)))
				w.Header().Set("Content-Length", fmt.Sprint(last-first+1))
				w.WriteHeader(206)
				_, _ = w.Write(data[first : last+1])
			}))
			defer server.Close()
			f := buildFetcher()
			defer f.Close()
			if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
				t.Fatal(err)
			}
			retries := 0
			if mode == "truncated-retry" {
				retries = 1
			}
			if err := f.Create(&base.Options{Name: "window.bin", Path: t.TempDir(), Extra: &fhttp.OptsExtra{Connections: 1, ConnectionProfile: "baidu_preview", RetryLimit: &retries}}); err != nil {
				t.Fatal(err)
			}
			if err := f.Start(); err != nil {
				t.Fatal(err)
			}
			err := f.Wait()
			switch mode {
			case "truncated-retry":
				if err != nil || !resumed.Load() {
					t.Fatalf("partial window retry err=%v resumed=%v", err, resumed.Load())
				}
				got, readErr := os.ReadFile(f.Meta().SingleFilepath())
				if readErr != nil || !bytes.Equal(got, data) {
					t.Fatal("retried window corrupted file contents")
				}
			case "truncated-exhausted":
				if !errors.Is(err, io.ErrUnexpectedEOF) || f.Progress()[0] != baiduPreviewRequestSize+1024 {
					t.Fatalf("incomplete response was accepted: err=%v progress=%v", err, f.Progress())
				}
			case "wrong-range":
				var status *RequestError
				if !errors.As(err, &status) || status.Code != 412 || f.Progress()[0] != baiduPreviewRequestSize {
					t.Fatalf("changed range was accepted: err=%v progress=%v", err, f.Progress())
				}
			}
		})
	}
}
