package transport

import (
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"time"
)

// pipeBufferSize bounds what one direction of a fake connection holds. Real
// TCP lets a writer run ahead of a slow reader by its socket buffers; net.Pipe
// does not, and two actors that both write before reading would deadlock on
// it. The bound keeps backpressure: a writer blocks once its peer is this far
// behind.
const pipeBufferSize = 256 << 10

// stream is one direction of a fake connection.
type stream struct {
	// mu guards the buffer between the reading and the writing goroutine.
	mu             sync.Mutex
	buf            []byte
	changed        chan struct{}
	isReaderClosed bool
	isWriterClosed bool
	readDeadline   time.Time
	writeDeadline  time.Time
}

func buildStream() *stream {
	return &stream{changed: make(chan struct{})}
}

// closeChanged wakes every waiter; it is called with s.mu held.
func (s *stream) closeChanged() {
	close(s.changed)
	s.changed = make(chan struct{})
}

func (s *stream) read(b []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		switch {
		case s.isReaderClosed:
			return 0, net.ErrClosed
		case len(s.buf) > 0:
			n := copy(b, s.buf)
			s.buf = s.buf[n:]
			s.closeChanged()
			return n, nil
		case s.isWriterClosed:
			return 0, io.EOF
		}
		if err := s.wait(s.readDeadline); err != nil {
			return 0, err
		}
	}
}

func (s *stream) write(b []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	written := 0
	for written < len(b) {
		switch {
		case s.isWriterClosed:
			return written, net.ErrClosed
		case s.isReaderClosed:
			return written, io.ErrClosedPipe
		}
		if space := pipeBufferSize - len(s.buf); space > 0 {
			n := min(space, len(b)-written)
			s.buf = append(s.buf, b[written:written+n]...)
			written += n
			s.closeChanged()
			continue
		}
		if err := s.wait(s.writeDeadline); err != nil {
			return written, err
		}
	}
	return written, nil
}

// wait releases s.mu until the stream changes or the deadline passes.
func (s *stream) wait(deadline time.Time) error {
	if !deadline.IsZero() && !time.Now().Before(deadline) {
		return os.ErrDeadlineExceeded
	}
	changed := s.changed
	s.mu.Unlock()
	defer s.mu.Lock()
	if deadline.IsZero() {
		<-changed
		return nil
	}
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case <-changed:
	case <-timer.C:
	}
	return nil
}

func (s *stream) setDeadline(deadline *time.Time, t time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	*deadline = t
	s.closeChanged()
}

func (s *stream) closeReader() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.isReaderClosed = true
	s.buf = nil
	s.closeChanged()
}

func (s *stream) closeWriter() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.isWriterClosed = true
	s.closeChanged()
}

// pipeConn is one end of a fake TCP connection.
// Deadlines use the wall clock, as net.Conn requires; the engine times
// connections out through its clock instead.
type pipeConn struct {
	in, out       *stream
	local, remote *net.TCPAddr
	onClosed      func()
	closeOnce     sync.Once
}

func createPipe(a, b netip.AddrPort) (*pipeConn, *pipeConn) {
	ab, ba := buildStream(), buildStream()
	aAddr, bAddr := net.TCPAddrFromAddrPort(a), net.TCPAddrFromAddrPort(b)
	return &pipeConn{in: ba, out: ab, local: aAddr, remote: bAddr},
		&pipeConn{in: ab, out: ba, local: bAddr, remote: aAddr}
}

func (c *pipeConn) Read(b []byte) (int, error)  { return c.in.read(b) }
func (c *pipeConn) Write(b []byte) (int, error) { return c.out.write(b) }
func (c *pipeConn) LocalAddr() net.Addr         { return c.local }
func (c *pipeConn) RemoteAddr() net.Addr        { return c.remote }

func (c *pipeConn) SetDeadline(t time.Time) error {
	c.SetReadDeadline(t)
	return c.SetWriteDeadline(t)
}

func (c *pipeConn) SetReadDeadline(t time.Time) error {
	c.in.setDeadline(&c.in.readDeadline, t)
	return nil
}

func (c *pipeConn) SetWriteDeadline(t time.Time) error {
	c.out.setDeadline(&c.out.writeDeadline, t)
	return nil
}

func (c *pipeConn) Close() error {
	err := net.ErrClosed
	c.closeOnce.Do(func() {
		c.in.closeReader()
		c.out.closeWriter()
		if c.onClosed != nil {
			c.onClosed()
		}
		err = nil
	})
	return err
}
