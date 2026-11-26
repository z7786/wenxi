package http

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	gohttp "net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestTimeoutReader_Read(t *testing.T) {
	data := []byte("Hello, World!")
	reader := bytes.NewReader(data)
	timeoutReader := NewTimeoutReader(reader, 1*time.Second)

	buf := make([]byte, len(data))
	n, err := timeoutReader.Read(buf)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if n != len(data) {
		t.Fatalf("expected to read %d bytes, read %d", len(data), n)
	}
	if !bytes.Equal(buf, data) {
		t.Fatalf("expected %s, got %s", data, buf)
	}
}

func TestTimeoutReader_ReadTimeout(t *testing.T) {
	reader := &slowReader{delay: 2 * time.Second}
	timeoutReader := NewTimeoutReader(reader, 1*time.Second)

	buf := make([]byte, 8192)
	_, err := timeoutReader.Read(buf)
	if err == nil {
		t.Fatal("expected timeout error, got nil")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected %v, got %v", context.DeadlineExceeded, err)
	}
}

func TestReadTimeoutConn_ReadTimeout(t *testing.T) {
	c1, c2 := net.Pipe()
	defer c1.Close()
	defer c2.Close()

	wrapped := &readTimeoutConn{Conn: c1, timeout: 60 * time.Millisecond}
	buf := make([]byte, 16)
	_, err := wrapped.Read(buf)
	if err == nil {
		t.Fatal("expected read timeout error, got nil")
	}
	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("expected net.Error timeout, got %T: %v", err, err)
	}
}

func TestReadTimeoutConn_PreservesEarlierCallerDeadline(t *testing.T) {
	t.Run("SetReadDeadline", func(t *testing.T) {
		c1, c2 := net.Pipe()
		defer c1.Close()
		defer c2.Close()

		drainDone := make(chan struct{})
		go func() {
			defer close(drainDone)
			var b [1]byte
			_, _ = c2.Read(b[:])
		}()

		wrapped := &readTimeoutConn{Conn: c1, timeout: 5 * time.Second}
		if err := wrapped.SetReadDeadline(time.Unix(1, 0)); err != nil {
			t.Fatalf("SetReadDeadline failed: %v", err)
		}

		// Write must not overwrite or extend the earlier caller read deadline.
		if _, err := wrapped.Write([]byte("x")); err != nil {
			t.Fatalf("Write failed: %v", err)
		}
		<-drainDone

		start := time.Now()
		buf := make([]byte, 16)
		_, err := wrapped.Read(buf)
		elapsed := time.Since(start)
		if err == nil {
			t.Fatal("expected read timeout error, got nil")
		}
		var netErr net.Error
		if !errors.As(err, &netErr) || !netErr.Timeout() {
			t.Fatalf("expected net.Error timeout, got %T: %v", err, err)
		}
		if elapsed > 500*time.Millisecond {
			t.Fatalf("Read waited %v instead of honoring earlier caller deadline", elapsed)
		}

		// Clearing the caller deadline should restore normal reads.
		if err := wrapped.SetReadDeadline(time.Time{}); err != nil {
			t.Fatalf("clearing SetReadDeadline failed: %v", err)
		}
		go func() {
			_, _ = c2.Write([]byte("ok"))
		}()
		n, err := wrapped.Read(buf)
		if err != nil {
			t.Fatalf("expected read to succeed after clearing deadline, got %v", err)
		}
		if string(buf[:n]) != "ok" {
			t.Fatalf("expected %q, got %q", "ok", string(buf[:n]))
		}
	})

	t.Run("SetDeadline", func(t *testing.T) {
		c1, c2 := net.Pipe()
		defer c1.Close()
		defer c2.Close()

		wrapped := &readTimeoutConn{Conn: c1, timeout: 5 * time.Second}
		if err := wrapped.SetDeadline(time.Unix(1, 0)); err != nil {
			t.Fatalf("SetDeadline failed: %v", err)
		}

		start := time.Now()
		buf := make([]byte, 16)
		_, err := wrapped.Read(buf)
		elapsed := time.Since(start)
		if err == nil {
			t.Fatal("expected read timeout error, got nil")
		}
		var netErr net.Error
		if !errors.As(err, &netErr) || !netErr.Timeout() {
			t.Fatalf("expected net.Error timeout, got %T: %v", err, err)
		}
		if elapsed > 500*time.Millisecond {
			t.Fatalf("Read waited %v instead of honoring earlier SetDeadline", elapsed)
		}
	})
}

func TestFetcher_SharedTransportAnd64KiBSpeedLimit(t *testing.T) {
	payload := bytes.Repeat([]byte("abcdefgh"), 32*1024) // 256 KiB
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseServer := func() {
		releaseOnce.Do(func() { close(release) })
	}
	defer releaseServer()

	var blockDownloads atomic.Bool
	srv := httptest.NewServer(gohttp.HandlerFunc(func(w gohttp.ResponseWriter, r *gohttp.Request) {
		if blockDownloads.Load() {
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		gohttp.ServeContent(w, r, "sample.bin", time.Now(), bytes.NewReader(payload))
	}))
	defer srv.Close()

	f := buildFetcher()
	req := &base.Request{URL: srv.URL + "/sample.bin"}
	if err := f.Resolve(req); err != nil {
		t.Fatalf("Resolve failed: %v", err)
	}
	dir := t.TempDir()
	out := filepath.Join(dir, "sample.bin")
	if err := f.Create(&base.Options{
		Path: dir,
		Name: "sample.bin",
		Extra: &fhttp.OptsExtra{
			Connections: 4,
			SpeedLimit:  512 * 1024, // exercises 64 KiB read buffer + 64 KiB rate limiter burst
		},
	}); err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	blockDownloads.Store(true)
	if err := f.Start(); err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	c1 := f.buildClient()
	c2 := f.buildClient()
	if c1.Transport == nil || c1.Transport != c2.Transport {
		t.Fatalf("expected shared http.Transport across workers, got %p vs %p", c1.Transport, c2.Transport)
	}
	releaseServer()
	if err := f.Wait(); err != nil {
		t.Fatalf("Wait failed: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("downloaded payload mismatch: got %d bytes, want %d", len(got), len(payload))
	}
}

func TestFetcher_LowSpeedLimit(t *testing.T) {
	payload := bytes.Repeat([]byte("01234567"), 768) // 6 KiB
	srv := httptest.NewServer(gohttp.HandlerFunc(func(w gohttp.ResponseWriter, r *gohttp.Request) {
		gohttp.ServeContent(w, r, "low.bin", time.Now(), bytes.NewReader(payload))
	}))
	defer srv.Close()

	f := buildFetcher()
	req := &base.Request{URL: srv.URL + "/low.bin"}
	if err := f.Resolve(req); err != nil {
		t.Fatalf("Resolve failed: %v", err)
	}
	dir := t.TempDir()
	out := filepath.Join(dir, "low.bin")
	if err := f.Create(&base.Options{
		Path: dir,
		Name: "low.bin",
		Extra: &fhttp.OptsExtra{
			Connections: 2,
			SpeedLimit:  4 * 1024, // 4 KiB/s (< 64 KiB readBufSize)
		},
	}); err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	if err := f.Start(); err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	if err := f.Wait(); err != nil {
		t.Fatalf("Wait failed under low SpeedLimit: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("downloaded payload mismatch: got %d bytes, want %d", len(got), len(payload))
	}
}

type slowReader struct {
	delay time.Duration
}

func (sr *slowReader) Read(p []byte) (n int, err error) {
	time.Sleep(sr.delay)
	return 0, io.EOF
}

// Closing a response does not give an arbitrary Reader a guarantee that its
// in-flight Read has returned. A late read must never retain the worker's
// buffer, which the next HTTP request will reuse at a different file offset.
func TestTimeoutReaderLateReadCannotOverwriteRetryBuffer(t *testing.T) {
	reader := &gatedLateReader{release: make(chan struct{}), finished: make(chan struct{})}
	timeoutReader := NewTimeoutReader(reader, 10*time.Millisecond)
	buf := make([]byte, 8192)
	if n, err := timeoutReader.Read(buf); n != 0 || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected cancelled read, got %d %v", n, err)
	}
	// The failed response must not launch another read against its buffer.
	if n, err := timeoutReader.Read(buf); n != 0 || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timed-out response was reused: %d %v", n, err)
	}
	// Model the next successful request filling the same download buffer.
	want := bytes.Repeat([]byte{0x5a}, len(buf))
	copy(buf, want)
	close(reader.release)
	<-reader.finished
	if !bytes.Equal(buf, want) {
		t.Fatal("timed-out response overwrote the next request's download bytes")
	}
}

func TestTimeoutReaderPreservesBytesReturnedWithEOF(t *testing.T) {
	reader := NewTimeoutReader(finalBytesReader{}, time.Second)
	buf := make([]byte, 16)
	n, err := reader.Read(buf)
	if n != 4 || err != io.EOF || !bytes.Equal(buf[:n], []byte("tail")) {
		t.Fatalf("final bytes were lost: %q %d %v", buf[:n], n, err)
	}
}

type finalBytesReader struct{}

func (finalBytesReader) Read(buf []byte) (int, error) {
	return copy(buf, "tail"), io.EOF
}

type gatedLateReader struct {
	release, finished chan struct{}
}

func (reader *gatedLateReader) Read(buf []byte) (int, error) {
	<-reader.release
	for i := range buf {
		buf[i] = 0xa5
	}
	close(reader.finished)
	return len(buf), nil
}
