package engine

import (
	"context"
	"math"
	"sync"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/clock"
)

// rateLimiter is a token bucket shared by every peer connection in one
// direction. Their reader and writer goroutines call waitN before moving n bytes,
// protocol overhead included; writers call addControl instead for control
// packets.
//
// The bucket counts bytes cumulatively: reserved is every byte callers asked
// for, paid is every byte the rate has covered. A caller reserves its bytes
// and returns once paid reaches the end of its reservation, so callers pass in
// order, any n is paced exactly, and a rate change applies to callers already
// waiting.
type rateLimiter struct {
	clock clock.Clock
	// mu guards the bucket, which ADR-0005 keeps as shared memory: every
	// connection's reader and writer leaf calls waitN, the hub setRate.
	mu       sync.Mutex
	rate     float64
	reserved float64
	paid     float64
	last     time.Time
	changed  chan struct{}
}

// buildRateLimiter builds an unlimited rateLimiter.
func buildRateLimiter(c clock.Clock) *rateLimiter {
	return &rateLimiter{clock: c, last: c.Now(), changed: make(chan struct{})}
}

// setRate sets the rate in bytes per second; 0 means unlimited.
func (l *rateLimiter) setRate(rate int64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.clock.Now()
	if l.rate == 0 {
		l.paid = l.reserved
		l.last = now
	} else {
		l.updatePaid(now)
	}
	l.rate = float64(rate)
	close(l.changed)
	l.changed = make(chan struct{})
}

// waitN blocks until n bytes may pass. Bytes of a cancelled call stay
// reserved.
func (l *rateLimiter) waitN(ctx context.Context, n int) error {
	l.mu.Lock()
	if l.rate == 0 {
		l.mu.Unlock()
		return nil
	}
	l.updatePaid(l.clock.Now())
	l.reserved += float64(n)
	end := l.reserved
	for {
		if l.rate == 0 || l.paid >= end {
			l.mu.Unlock()
			return nil
		}
		wait := time.Duration(math.Ceil((end - l.paid) / l.rate * float64(time.Second)))
		changed := l.changed
		l.mu.Unlock()

		timer := l.clock.CreateTimer(wait)
		select {
		case <-timer.C():
		case <-changed:
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		}
		timer.Stop()
		l.mu.Lock()
		l.updatePaid(l.clock.Now())
	}
}

// addControl counts the n bytes of a control packet, which passes at once:
// like aMule's throttler, which sends control packets before any upload data
// (UploadBandwidthThrottler.cpp:350-), it goes ahead of every waiting caller,
// and they wait n/rate longer, so the rate holds.
func (l *rateLimiter) addControl(n int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.rate == 0 {
		return
	}
	l.updatePaid(l.clock.Now())
	l.paid -= float64(n)
}

// burst is a quarter second of rate: enough that waiters wake rarely, little
// enough that the burst after an idle spell hardly shows in the observed rate.
func (l *rateLimiter) burst() float64 {
	return l.rate / 4
}

// updatePaid is called with l.mu held.
func (l *rateLimiter) updatePaid(now time.Time) {
	if elapsed := now.Sub(l.last).Seconds(); elapsed > 0 {
		l.paid = min(l.paid+elapsed*l.rate, l.reserved+l.burst())
	}
	l.last = now
}
