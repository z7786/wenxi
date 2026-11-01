package transfer

import "time"

const meterWindow = 5 * time.Second

type sample struct {
	at    time.Time
	bytes int64
}

// meter measures a byte rate over the last meterWindow.
type meter struct{ samples []sample }

func (m *meter) add(now time.Time, bytes int64) {
	m.clear(now)
	m.samples = append(m.samples, sample{at: now, bytes: bytes})
}

func (m *meter) clear(now time.Time) {
	kept := m.samples[:0]
	for _, s := range m.samples {
		if now.Sub(s.at) < meterWindow {
			kept = append(kept, s)
		}
	}
	m.samples = kept
}

// rate is in bytes per second.
func (m *meter) rate(now time.Time) int64 {
	var total int64
	for _, s := range m.samples {
		if now.Sub(s.at) < meterWindow {
			total += s.bytes
		}
	}
	return total * int64(time.Second) / int64(meterWindow)
}
