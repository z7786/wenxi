package clock

import (
	"sync"
	"time"
)

// Fake is a Clock that moves only when Advance is called.
type Fake struct {
	// mu guards time and the waits: the test advances while leaves wait.
	mu    sync.Mutex
	now   time.Time
	waits []*fakeWait
}

func BuildFake(start time.Time) *Fake {
	return &Fake{now: start}
}

func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *Fake) CreateTicker(d time.Duration) Timer {
	if d <= 0 {
		panic("clock: non-positive ticker interval")
	}
	return f.addWait(d, d)
}

// CreateTimer fires once after d; a d of zero or less fires on the next
// Advance.
func (f *Fake) CreateTimer(d time.Duration) Timer {
	return f.addWait(max(d, 0), 0)
}

func (f *Fake) addWait(d, period time.Duration) *fakeWait {
	f.mu.Lock()
	defer f.mu.Unlock()
	w := &fakeWait{clock: f, c: make(chan time.Time, 1), period: period, next: f.now.Add(d)}
	f.waits = append(f.waits, w)
	return w
}

// Waiters is the number of pending timers plus running tickers with no tick
// waiting to be received: roughly, the goroutines parked on this clock. A test
// advances only while it is positive, so that time does not run ahead of the
// code under test.
func (f *Fake) Waiters() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	count := 0
	for _, w := range f.waits {
		if len(w.c) == 0 {
			count++
		}
	}
	return count
}

// Advance moves time forward by d and fires every timer and tick that falls
// due, in time order. Like time.Ticker, a tick is dropped when the previous
// one has not been received yet.
func (f *Fake) Advance(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	end := f.now.Add(d)
	for {
		var due *fakeWait
		for _, w := range f.waits {
			if !w.next.After(end) && (due == nil || w.next.Before(due.next)) {
				due = w
			}
		}
		if due == nil {
			break
		}
		f.now = due.next
		select {
		case due.c <- due.next:
		default:
		}
		if due.period == 0 {
			f.removeWait(due)
		} else {
			due.next = due.next.Add(due.period)
		}
	}
	f.now = end
}

// fakeWait is a ticker, or a timer when period is 0.
type fakeWait struct {
	clock  *Fake
	c      chan time.Time
	period time.Duration
	next   time.Time
}

func (w *fakeWait) C() <-chan time.Time { return w.c }

func (w *fakeWait) Stop() {
	w.clock.mu.Lock()
	defer w.clock.mu.Unlock()
	w.clock.removeWait(w)
}

// removeWait is called with f.mu held.
func (f *Fake) removeWait(w *fakeWait) {
	for i, other := range f.waits {
		if other == w {
			f.waits = append(f.waits[:i], f.waits[i+1:]...)
			return
		}
	}
}
