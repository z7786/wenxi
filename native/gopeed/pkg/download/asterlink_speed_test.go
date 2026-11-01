package download

import (
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
)

func TestTransferRateUsesActualIrregularIntervals(t *testing.T) {
	var rate transferRate
	now := time.Now()
	rate.reset(1000, now)
	// The second refresh is delayed by checkpoint I/O. Both samples carry
	// 1000 bytes/second; using the last interval for all samples is incorrect.
	if got := rate.update(1500, now.Add(500*time.Millisecond)); got != 1000 {
		t.Fatalf("first speed=%d", got)
	}
	if got := rate.update(4000, now.Add(3*time.Second)); got != 1000 {
		t.Fatalf("delayed speed=%d", got)
	}
	if got := rate.update(11000, now.Add(10*time.Second)); got != 1000 {
		t.Fatalf("long sample speed=%d", got)
	}
	if got := rate.update(11000, now.Add(15*time.Second)); got != 0 {
		t.Fatalf("idle speed=%d", got)
	}
}

func TestTransferRateResumeRollbackAndNonRunning(t *testing.T) {
	var rate transferRate
	now := time.Now()
	if got := rate.update(1<<30, now); got != 0 {
		t.Fatalf("cached bytes counted as a transfer: %d", got)
	}
	if got := rate.update(1<<30+100, now.Add(time.Second)); got != 100 {
		t.Fatalf("new bytes=%d", got)
	}
	rate.reset(1<<30+100, now.Add(time.Hour))
	if got := rate.update(1<<30+300, now.Add(time.Hour+time.Second)); got != 200 {
		t.Fatalf("resume speed=%d", got)
	}
	if got := rate.update(50, now.Add(time.Hour+2*time.Second)); got != 0 {
		t.Fatalf("rollback speed=%d", got)
	}
	if got := rate.update(100, now.Add(time.Hour+3*time.Second)); got != 50 {
		t.Fatalf("post rollback speed=%d", got)
	}
	for _, status := range []base.Status{base.DownloadStatusPause, base.DownloadStatusDone, base.DownloadStatusError} {
		task := &Task{Progress: &Progress{Speed: 1 << 40}}
		task.updateStatus(status)
		if task.Progress.Speed != 0 {
			t.Fatalf("status=%s retains live speed", status)
		}
	}
}
