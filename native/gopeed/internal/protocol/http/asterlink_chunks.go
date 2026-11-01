package http

import "time"

func (c *connection) remaining() int64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.Chunk.remain()
}

func (c *connection) setRetryState(failed bool, attempts int) {
	c.mu.Lock()
	c.failed, c.retryTimes = failed, attempts
	c.mu.Unlock()
}

func (f *Fetcher) writeChunk(c *connection, data []byte) (finished bool, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	part := c.Chunk
	if f.meta.Res.Range {
		remaining := part.remain()
		if remaining <= 0 {
			return true, nil
		}
		if int64(len(data)) > remaining {
			data = data[:remaining]
		}
	}
	start := part.Begin + part.Downloaded
	n, err := f.file.WriteAt(data, start)
	if n > 0 {
		if f.meta.Res.Range {
			f.readable.add(start, start+int64(n))
		}
		part.Downloaded += int64(n)
		c.Downloaded += int64(n)
		c.tail.progress(int64(n), time.Now())
	}
	return f.meta.Res.Range && part.remain() <= 0, err
}
