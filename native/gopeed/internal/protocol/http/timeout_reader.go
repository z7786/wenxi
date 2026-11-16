package http

import (
	"context"
	"io"
	"time"
)

type TimeoutReader struct {
	reader  io.Reader
	timeout time.Duration
	buffer  []byte
	failed  error
}

func NewTimeoutReader(r io.Reader, timeout time.Duration) *TimeoutReader {
	return &TimeoutReader{
		reader:  r,
		timeout: timeout,
	}
}

func (tr *TimeoutReader) Read(p []byte) (n int, err error) {
	if tr.failed != nil {
		return 0, tr.failed
	}
	if len(p) == 0 {
		return 0, nil
	}
	if len(tr.buffer) < len(p) {
		tr.buffer = make([]byte, len(p))
	}
	// A timeout can return before the underlying Read finishes, even while
	// closing its HTTP response. Never lend that read the caller's buffer:
	// the next range request may already be reusing it for different bytes.
	buffer := tr.buffer[:len(p)]
	ctx, cancel := context.WithTimeout(context.Background(), tr.timeout)
	defer cancel()

	done := make(chan struct{})
	var readErr error
	var bytesRead int

	go func() {
		bytesRead, readErr = tr.reader.Read(buffer)
		close(done)
	}()

	select {
	case <-done:
		copy(p, buffer[:bytesRead])
		return bytesRead, readErr
	case <-ctx.Done():
		// Retire this response after a timeout. Its private buffer remains
		// owned by the late read; a retry constructs a fresh TimeoutReader.
		tr.failed = ctx.Err()
		return 0, tr.failed
	}
}
