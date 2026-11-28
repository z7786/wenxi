package http

import (
	"context"
	"io"
	"net"
	"sync"
	"time"
)

type readTimeoutConn struct {
	net.Conn
	timeout            time.Duration
	mu                 sync.Mutex
	callerReadDeadline time.Time
}

func wrapDialReadTimeout(dial func(ctx context.Context, network, addr string) (net.Conn, error), timeout time.Duration) func(ctx context.Context, network, addr string) (net.Conn, error) {
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		conn, err := dial(ctx, network, addr)
		if err != nil {
			return nil, err
		}
		if timeout <= 0 {
			return conn, nil
		}
		return &readTimeoutConn{Conn: conn, timeout: timeout}, nil
	}
}

func (c *readTimeoutConn) SetDeadline(t time.Time) error {
	c.mu.Lock()
	c.callerReadDeadline = t
	err := c.Conn.SetDeadline(t)
	c.mu.Unlock()
	return err
}

func (c *readTimeoutConn) SetReadDeadline(t time.Time) error {
	c.mu.Lock()
	c.callerReadDeadline = t
	err := c.Conn.SetReadDeadline(t)
	c.mu.Unlock()
	return err
}

func (c *readTimeoutConn) applyReadDeadline() {
	if c.timeout <= 0 {
		return
	}
	c.mu.Lock()
	effective := time.Now().Add(c.timeout)
	if !c.callerReadDeadline.IsZero() && c.callerReadDeadline.Before(effective) {
		effective = c.callerReadDeadline
	}
	_ = c.Conn.SetReadDeadline(effective)
	c.mu.Unlock()
}

func (c *readTimeoutConn) Read(b []byte) (int, error) {
	c.applyReadDeadline()
	return c.Conn.Read(b)
}

func (c *readTimeoutConn) Write(b []byte) (int, error) {
	// Refresh read deadline when sending a new request over a reused pooled
	// connection whose background readLoop is already blocked in Peek.
	c.applyReadDeadline()
	return c.Conn.Write(b)
}

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
