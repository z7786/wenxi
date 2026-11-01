package gopeed

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Match the preview CDN: probes and small ranges work, a whole-file range fails.
func TestBaiduPreviewBoundedRequestsAndRestart(t *testing.T) {
	for _, connections := range []int{1, 4} {
		for _, restart := range []bool{false, true} {
			t.Run(fmt.Sprintf("connections=%d/restart=%t", connections, restart), func(t *testing.T) {
				storage, payload, key := openTestCore(t)
				const window = 8 * 1024 * 1024
				data := make([]byte, 6*window+137)
				for i := range data {
					data[i] = byte((i*37 + i/1009) % 251)
				}
				var requests, active, peak atomic.Int32
				var afterRestart atomic.Bool
				var resumedMu sync.Mutex
				var resumedOffsets []int64
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					var first, last int
					if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &first, &last); err != nil || first < 0 || last < first || last >= len(data) {
						w.WriteHeader(416)
						return
					}
					if last-first+1 > window {
						w.WriteHeader(403)
						return
					}
					if r.Header.Get("Cookie") != "test-cookie=local-only" || r.Header.Get("If-Range") != `"same-file"` {
						w.WriteHeader(401)
						return
					}
					if first != 0 || last != 0 {
						requests.Add(1)
						n := active.Add(1)
						defer active.Add(-1)
						for old := peak.Load(); n > old && !peak.CompareAndSwap(old, n); old = peak.Load() {
						}
						// Keep each request open long enough to observe the parallel
						// request budget even on a fast local loopback connection.
						time.Sleep(15 * time.Millisecond)
						if afterRestart.Load() {
							resumedMu.Lock()
							resumedOffsets = append(resumedOffsets, int64(first))
							resumedMu.Unlock()
						}
					}
					w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, len(data)))
					w.Header().Set("Content-Length", fmt.Sprint(last-first+1))
					w.WriteHeader(206)
					_, _ = w.Write(data[first : last+1])
				}))
				defer server.Close()
				input := request{ID: "baidu-preview-windows", URL: server.URL + "/file", Connections: connections,
					ConnectionProfile: "baidu_preview", Retries: 0,
					Headers: map[string]string{"Cookie": "test-cookie=local-only", "If-Range": `"same-file"`}}
				if restart {
					input.SpeedLimit = window
				}
				raw, _ := json.Marshal(input)
				if err := Begin(string(raw)); err != nil {
					t.Fatal(err)
				}
				if restart {
					waitState(t, input.ID, func(s snapshot) bool { return s.Downloaded > window && s.Status != "done" })
					if err := Pause(input.ID); err != nil {
						t.Fatal(err)
					}
					paused := waitState(t, input.ID, func(s snapshot) bool { return s.Status == "pause" })
					if err := Close(); err != nil {
						t.Fatal(err)
					}
					if err := Open(storage, payload, key); err != nil {
						t.Fatal(err)
					}
					deadline := time.Now().Add(time.Second)
					for active.Load() != 0 && time.Now().Before(deadline) {
						time.Sleep(time.Millisecond)
					}
					afterRestart.Store(true)
					input.URL = server.URL + "/refreshed"
					input.SpeedLimit = 0
					raw, _ = json.Marshal(input)
					if err := Begin(string(raw)); err != nil {
						t.Fatal(err)
					}
					state := waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
					assertPayload(t, state, data)
					resumedMu.Lock()
					defer resumedMu.Unlock()
					if len(resumedOffsets) == 0 || paused.Downloaded == 0 {
						t.Fatal("resume did not preserve an existing partial download")
					}
					for _, first := range resumedOffsets {
						for _, saved := range paused.ReadableRanges {
							if first >= saved[0] && first < saved[1] {
								t.Fatalf("resumed request at %d overlaps saved range %v", first, saved)
							}
						}
					}
				} else {
					state := waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" })
					assertPayload(t, state, data)
					if requests.Load() < 7 || state.Downloaded != int64(len(data)) {
						t.Fatalf("requests=%d downloaded=%d", requests.Load(), state.Downloaded)
					}
				}
				if peak.Load() != int32(connections) {
					t.Fatalf("peak connections=%d, want %d", peak.Load(), connections)
				}
			})
		}
	}
}
