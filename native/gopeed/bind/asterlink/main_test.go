package gopeed

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type fixture struct {
	server    *httptest.Server
	data      []byte
	active    atomic.Int32
	peak      atomic.Int32
	ranges    atomic.Int32
	refreshed atomic.Int32
}

func serveFile(t *testing.T, size int, delay time.Duration) *fixture {
	t.Helper()
	f := &fixture{data: make([]byte, size)}
	for i := range f.data {
		f.data[i] = byte((i*37 + i/101) % 251)
	}
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/expired" {
			w.WriteHeader(403)
			return
		}
		if r.Header.Get("Cookie") != "test-cookie=local-only" {
			w.WriteHeader(401)
			return
		}
		if r.URL.Path == "/refreshed" {
			f.refreshed.Add(1)
		}
		if r.URL.Path == "/ignore-range" && r.Header.Get("Range") != "bytes=0-0" {
			w.Header().Set("Content-Length", fmt.Sprint(size))
			w.Write(f.data)
			return
		}
		begin, end := 0, size-1
		partial := r.Header.Get("Range") != ""
		if partial {
			if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &begin, &end); err != nil || begin < 0 || end < begin || end >= size {
				w.WriteHeader(416)
				return
			}
		}
		running := f.active.Add(1)
		defer f.active.Add(-1)
		for old := f.peak.Load(); running > old && !f.peak.CompareAndSwap(old, running); old = f.peak.Load() {
		}
		if end > begin {
			f.ranges.Add(1)
			time.Sleep(delay)
		}
		w.Header().Set("Content-Length", fmt.Sprint(end-begin+1))
		if partial {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", begin, end, size))
			w.WriteHeader(206)
		}
		for begin <= end {
			n := min(8192, end-begin+1)
			if _, err := w.Write(f.data[begin : begin+n]); err != nil {
				return
			}
			begin += n
		}
	}))
	t.Cleanup(f.server.Close)
	return f
}
func openTestCore(t *testing.T) (string, string, string) {
	t.Helper()
	root := t.TempDir()
	storage, payload := filepath.Join(root, "state"), filepath.Join(root, "payload")
	key := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	if err := Open(storage, payload, key); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := Close(); err != nil {
			t.Error(err)
		}
	})
	return storage, payload, key
}
func startFile(t *testing.T, id, url string, connections int, limit int64) {
	t.Helper()
	raw, _ := json.Marshal(request{ID: id, URL: url, Headers: map[string]string{"Cookie": "test-cookie=local-only"}, Connections: connections, Retries: 3, SpeedLimit: limit})
	if err := Begin(string(raw)); err != nil {
		t.Fatal(err)
	}
}
func waitState(t *testing.T, id string, condition func(snapshot) bool, timeout ...time.Duration) snapshot {
	t.Helper()
	limit := 15 * time.Second
	if len(timeout) > 0 {
		limit = timeout[0]
	}
	deadline := time.Now().Add(limit)
	var state snapshot
	for time.Now().Before(deadline) {
		raw, err := Snapshot(id)
		if err != nil {
			t.Fatal(err)
		}
		if err = json.Unmarshal([]byte(raw), &state); err != nil {
			t.Fatal(err)
		}
		if condition(state) {
			return state
		}
		if state.Status == "error" {
			t.Fatalf("unexpected error: %+v", state)
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out: %+v", state)
	return state
}
func assertPayload(t *testing.T, state snapshot, want []byte) {
	t.Helper()
	got, err := os.ReadFile(state.Path)
	if err != nil {
		t.Fatal(err)
	}
	if sha256.Sum256(got) != sha256.Sum256(want) {
		t.Fatal("payload checksum mismatch")
	}
}

func TestHTTPConnectionsHeadersAndEncryptedState(t *testing.T) {
	storage, _, _ := openTestCore(t)
	f := serveFile(t, 4*1024*1024, 50*time.Millisecond)
	startFile(t, "parallel", f.server.URL+"/file", 64, 0)
	state := waitState(t, "parallel", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, f.data)
	if f.peak.Load() <= 8 {
		t.Fatalf("connections unexpectedly capped: %d", f.peak.Load())
	}
	raw, err := os.ReadFile(filepath.Join(storage, "gopeed.db"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("test-cookie")) || bytes.Contains(raw, []byte(f.server.URL)) {
		t.Fatal("credential or signed URL written in plaintext")
	}
}
func TestSmallFilesDoNotUse512Requests(t *testing.T) {
	openTestCore(t)
	f := serveFile(t, 4096, 0)
	startFile(t, "many", f.server.URL+"/file", 512, 0)
	assertPayload(t, waitState(t, "many", func(s snapshot) bool { return s.Status == "done" }), f.data)
	if f.ranges.Load() != 1 {
		t.Fatalf("expected one small-file range, got %d", f.ranges.Load())
	}
	tiny := serveFile(t, 7, 0)
	startFile(t, "tiny", tiny.server.URL+"/file", 512, 0)
	assertPayload(t, waitState(t, "tiny", func(s snapshot) bool { return s.Status == "done" }), tiny.data)
}

func TestQuark40MiBUses512RangesAndReportsCompletion(t *testing.T) {
	openTestCore(t)
	f := serveFile(t, 40*1024*1024, time.Millisecond)
	raw, _ := json.Marshal(request{ID: "quark-40mb", URL: f.server.URL + "/file",
		Headers:     map[string]string{"Cookie": "test-cookie=local-only"},
		Connections: 512, ConnectionProfile: "quark_route_1", Retries: 3})
	if err := Begin(string(raw)); err != nil {
		t.Fatal(err)
	}
	state := waitState(t, "quark-40mb", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, f.data)
	if f.ranges.Load() != 512 || state.TotalConnections != 512 || state.ActiveConnections != 0 {
		t.Fatalf("ranges=%d final=%+v", f.ranges.Load(), state)
	}
}

func TestHTTPConnectionCountsAcrossPauseAndResume(t *testing.T) {
	storage, payload, key := openTestCore(t)
	f := serveFile(t, 2*1024*1024, 0)
	raw, _ := json.Marshal(request{ID: "connection-counts", URL: f.server.URL + "/file",
		Headers:     map[string]string{"Cookie": "test-cookie=local-only"},
		Connections: 512, ConnectionProfile: "quark_route_1", Retries: 3, SpeedLimit: 1024 * 1024})
	if err := Begin(string(raw)); err != nil {
		t.Fatal(err)
	}
	state := waitState(t, "connection-counts", func(s snapshot) bool { return s.ActiveConnections > 0 })
	if state.TotalConnections != 32 || state.ActiveConnections > 32 {
		t.Fatalf("invalid live counts: %+v", state)
	}
	if err := Pause("connection-counts"); err != nil {
		t.Fatal(err)
	}
	state = waitState(t, "connection-counts", func(s snapshot) bool { return s.Status == "pause" })
	if state.ActiveConnections != 0 {
		t.Fatalf("paused connections: %+v", state)
	}
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	if err := Open(storage, payload, key); err != nil {
		t.Fatal(err)
	}
	if err := Begin(string(raw)); err != nil {
		t.Fatal(err)
	}
	state = waitState(t, "connection-counts", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, f.data)
	if state.TotalConnections != 32 || state.ActiveConnections != 0 {
		t.Fatalf("resumed counts: %+v", state)
	}
}

func TestHTTPConnectionCountsExcludeCooldown(t *testing.T) {
	openTestCore(t)
	var rejected atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") == "bytes=0-0" {
			w.Header().Set("Content-Range", "bytes 0-0/41943040")
			w.Header().Set("Content-Length", "1")
			w.WriteHeader(206)
			w.Write([]byte{0})
			return
		}
		rejected.Store(true)
		w.Header().Set("Retry-After", "3")
		w.WriteHeader(429)
	}))
	defer server.Close()
	raw, _ := json.Marshal(request{ID: "counts-cooldown", URL: server.URL + "/file",
		Connections: 8, ConnectionProfile: "quark_route_1", Retries: 3})
	if err := Begin(string(raw)); err != nil {
		t.Fatal(err)
	}
	state := waitState(t, "counts-cooldown", func(s snapshot) bool {
		return rejected.Load() && s.TotalConnections == 8 && s.ActiveConnections == 0
	})
	if state.Status != "running" {
		t.Fatalf("cooldown state: %+v", state)
	}
	if err := Pause("counts-cooldown"); err != nil {
		t.Fatal(err)
	}
}

func TestBaiduUpgradesLegacySingleConnectionCheckpoint(t *testing.T) {
	for _, tc := range []struct {
		profile string
		limit   int
	}{
		{"baidu", 4}, {"baidu_preview", 4},
	} {
		t.Run(tc.profile, func(t *testing.T) {
			storage, payload, key := openTestCore(t)
			f := serveFile(t, 2*1024*1024, 30*time.Millisecond)
			startFile(t, "baidu-resume", f.server.URL+"/file", 1, 1024*1024)
			waitState(t, "baidu-resume", func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
			if err := Pause("baidu-resume"); err != nil {
				t.Fatal(err)
			}
			if err := Close(); err != nil {
				t.Fatal(err)
			}
			if err := Open(storage, payload, key); err != nil {
				t.Fatal(err)
			}
			deadline := time.Now().Add(time.Second)
			for f.active.Load() != 0 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if f.active.Load() != 0 {
				t.Fatal("old requests did not stop")
			}
			f.peak.Store(0)
			raw, _ := json.Marshal(request{ID: "baidu-resume", URL: f.server.URL + "/refreshed",
				Headers:     map[string]string{"Cookie": "test-cookie=local-only"},
				Connections: tc.limit, ConnectionProfile: tc.profile, Retries: 3})
			if err := Begin(string(raw)); err != nil {
				t.Fatal(err)
			}
			state := waitState(t, "baidu-resume", func(s snapshot) bool { return s.Status == "done" })
			assertPayload(t, state, f.data)
			// A completed saved range can occupy a checkpoint slot. Unread tails
			// must run in parallel without exceeding the requested budget.
			if f.peak.Load() < 2 || f.peak.Load() > int32(tc.limit) || state.TotalConnections != tc.limit {
				t.Fatalf("peak=%d total=%d, budget=%d", f.peak.Load(), state.TotalConnections, tc.limit)
			}
		})
	}
}

func TestPauseResumeAfterProcessRestartAndURLRefresh(t *testing.T) {
	storage, payload, key := openTestCore(t)
	f := serveFile(t, 2*1024*1024, 0)
	startFile(t, "resume", f.server.URL+"/file", 8, 1024*1024)
	waitState(t, "resume", func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Pause("resume"); err != nil {
		t.Fatal(err)
	}
	filename := filepath.Join(payload, "resume", "payload.gopeed")
	before, err := os.ReadFile(filename)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(120 * time.Millisecond)
	after, _ := os.ReadFile(filename)
	if !bytes.Equal(before, after) {
		t.Fatal("writers still active after pause returned")
	}
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	if err := Open(storage, payload, key); err != nil {
		t.Fatal(err)
	}
	startFile(t, "resume", f.server.URL+"/refreshed", 8, 1024*1024)
	assertPayload(t, waitState(t, "resume", func(s snapshot) bool { return s.Status == "done" }), f.data)
	if f.refreshed.Load() == 0 {
		t.Fatal("new signed URL was not used")
	}
}
func TestHTTPErrorAndRangeChangeReachAndroid(t *testing.T) {
	openTestCore(t)
	f := serveFile(t, 1024*1024, 0)
	startFile(t, "expired", f.server.URL+"/expired", 32, 0)
	state := waitState(t, "expired", func(s snapshot) bool { return s.Status == "error" })
	if state.HTTPCode != 403 {
		t.Fatalf("want 403, got %+v", state)
	}
	startFile(t, "range", f.server.URL+"/ignore-range", 16, 0)
	state = waitState(t, "range", func(s snapshot) bool { return s.Status == "error" })
	if state.HTTPCode != 412 {
		t.Fatalf("want range-change signal, got %+v", state)
	}
}
func TestRemoveStopsWritesAndForgetsTask(t *testing.T) {
	_, payload, _ := openTestCore(t)
	f := serveFile(t, 2*1024*1024, 0)
	startFile(t, "remove", f.server.URL+"/file", 8, 512*1024)
	waitState(t, "remove", func(s snapshot) bool { return s.Downloaded > 0 })
	if err := Remove("remove"); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(payload, "remove", "payload.gopeed"))
	time.Sleep(120 * time.Millisecond)
	after, _ := os.ReadFile(filepath.Join(payload, "remove", "payload.gopeed"))
	if !bytes.Equal(before, after) {
		t.Fatal("writers still active after removal")
	}
	if _, err := Snapshot("remove"); err == nil {
		t.Fatal("removed task still visible")
	}
}
func TestInvalidPathAndConnectionsRejected(t *testing.T) {
	openTestCore(t)
	for _, value := range []request{{ID: "../escape", URL: "https://example.com/a", Connections: 1}, {ID: "invalid", URL: "https://example.com/a", Connections: 513}, {ID: "invalid", URL: "file:///etc/passwd", Connections: 1}} {
		raw, _ := json.Marshal(value)
		if err := Begin(string(raw)); err == nil {
			t.Fatal("invalid input accepted")
		}
	}
}
func TestEncryptedStorageAuthentication(t *testing.T) {
	dir := t.TempDir()
	store, err := newEncryptedStorage(dir, bytes.Repeat([]byte{3}, 32))
	if err != nil {
		t.Fatal(err)
	}
	if err = store.Setup([]string{"task"}); err != nil {
		t.Fatal(err)
	}
	if err = store.Put("task", "one", map[string]string{"secret": "test-secret"}); err != nil {
		t.Fatal(err)
	}
	if err = store.Close(); err != nil {
		t.Fatal(err)
	}
	other, err := newEncryptedStorage(dir, bytes.Repeat([]byte{4}, 32))
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	var value map[string]string
	if _, err = other.Get("task", "one", &value); err == nil || !strings.Contains(err.Error(), "decrypt") {
		t.Fatal("wrong key accepted")
	}
}
