package http

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"
	"time"
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
