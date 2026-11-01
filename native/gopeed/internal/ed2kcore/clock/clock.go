// Package clock is the engine's seam for time.
package clock

import "time"

type Clock interface {
	Now() time.Time
	// CreateTicker fires every d, dropping a tick while the last one waits
	// to be received.
	CreateTicker(d time.Duration) Timer
	CreateTimer(d time.Duration) Timer
}

// Timer delivers on C until it is stopped: once, or every period of a
// ticker.
type Timer interface {
	C() <-chan time.Time
	Stop()
}

// Real is the Clock of the running process.
type Real struct{}

func (Real) Now() time.Time { return time.Now() }

func (Real) CreateTicker(d time.Duration) Timer {
	ticker := time.NewTicker(d)
	return realTimer{ticker.C, ticker.Stop}
}

func (Real) CreateTimer(d time.Duration) Timer {
	timer := time.NewTimer(d)
	return realTimer{timer.C, func() { timer.Stop() }}
}

type realTimer struct {
	c    <-chan time.Time
	stop func()
}

func (t realTimer) C() <-chan time.Time { return t.c }

func (t realTimer) Stop() { t.stop() }
