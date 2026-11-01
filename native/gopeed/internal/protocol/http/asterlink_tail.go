package http

import (
	"context"
	"time"
)

const (
	// A small range is worthwhile only when measured transfer time is long.
	// Each new half still owns at least 16 KiB; fast tails keep their request.
	tailMinRangeSize  int64 = 16 * 1024
	tailWarmup              = 750 * time.Millisecond
	tailSampleWindow        = time.Second
	tailTargetTime          = 3 * time.Second
	tailCheckInterval       = 500 * time.Millisecond
)

// Transient response throughput, protected by connection.mu. Checkpoints do
// not retain timing measurements across pauses, restarts or source refreshes.
type tailSample struct {
	started, window time.Time
	bytes           int64
	rate            float64
}

func (sample *tailSample) start(now time.Time) {
	*sample = tailSample{started: now, window: now}
}

func (sample *tailSample) progress(bytes int64, now time.Time) {
	if sample.started.IsZero() {
		return
	}
	sample.bytes += bytes
	if elapsed := now.Sub(sample.window); elapsed >= tailSampleWindow {
		sample.rate = float64(sample.bytes) / elapsed.Seconds()
		sample.window = now
		sample.bytes = 0
	}
}

func (sample *tailSample) slow(remaining int64, now time.Time) bool {
	if remaining < 2*tailMinRangeSize || sample.started.IsZero() || now.Sub(sample.started) < tailWarmup {
		return false
	}
	speed := sample.rate
	// Include a recent stall instead of trusting an older fast sample forever.
	if elapsed := now.Sub(sample.window); speed <= 0 || elapsed >= tailSampleWindow {
		if elapsed <= 0 {
			return false
		}
		speed = float64(sample.bytes) / elapsed.Seconds()
	}
	return speed <= 0 || float64(remaining)/speed > tailTargetTime.Seconds()
}

func (f *Fetcher) notifyTailChanged() {
	f.helpLock.Lock()
	defer f.helpLock.Unlock()
	if f.tailChanged != nil {
		close(f.tailChanged)
		f.tailChanged = make(chan struct{})
	}
}

func (f *Fetcher) waitForOtherConnection(ctx context.Context, helper *connection) (bool, error) {
	var ticker *time.Ticker
	defer func() {
		if ticker != nil {
			ticker.Stop()
		}
	}()
	for {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		helped, pending, changed := f.helpOtherConnection(helper)
		if helped || !pending {
			return helped, nil
		}
		if ticker == nil {
			ticker = time.NewTicker(tailCheckInterval)
		}
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		case <-changed:
		case <-ticker.C:
		}
	}
}
