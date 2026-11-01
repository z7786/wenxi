package http

// AsterLink policy additions, 2026-09-14. Gopeed v1.8.1 (GPL-3.0).
import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

const minRangeSize int64 = 256 * 1024
const quarkRangeSize int64 = 64 * 1024
const aliyunConnections = 8

// Guangya can reject a 64-range burst with 503 even after normal retries.
// Reduce only an overloaded node; healthy nodes keep the configured budget.
var guangyaHosts = newAdaptiveHostLimiter(4, 2*time.Minute)

// Baidu's preview CDN accepts bounded reads but can reject a whole-file Range
// with 403/31326. Read consecutive bounded windows on each connection;
// checkpoint chunks continue to describe file ownership, not HTTP requests.
const baiduPreviewRequestSize int64 = 8 * 1024 * 1024

func effectiveConnections(size int64, configured int, profile string) int {
	if size <= 0 {
		return 1
	}
	if limit := fhttp.BaiduConnectionLimit(profile); limit > 0 {
		configured = min(configured, limit)
	}
	minimum := minRangeSize
	if profile == "aliyun" {
		// The original-file endpoint rejects bursts of large parallelism with
		// 503. Keep a modest window while respecting a smaller user ceiling.
		configured = min(configured, aliyunConnections)
	}
	if profile == "quark_route_1" {
		// Preserve the requested parallelism for ordinary Quark files (e.g.
		// 40 MiB at 512), while still bounding very small-file request overhead.
		minimum = quarkRangeSize
	}
	budget := (size-1)/minimum + 1
	return int(max(int64(1), min(int64(configured), int64(512), budget)))
}

func retryDelay(attempt int) time.Duration {
	delays := [...]time.Duration{2 * time.Second, 5 * time.Second, 10 * time.Second}
	return delays[min(max(attempt, 0), len(delays)-1)]
}

func responseError(response *http.Response) *RequestError {
	err := NewRequestError(response.StatusCode, response.Status)
	value := strings.TrimSpace(response.Header.Get("Retry-After"))
	if seconds, parseErr := strconv.ParseInt(value, 10, 64); parseErr == nil && seconds >= 0 {
		// Preserve a long server cooldown without overflowing time.Duration.
		seconds = min(seconds, int64((1<<63-1)/int64(time.Second)))
		err.RetryAfter = time.Now().Add(time.Duration(seconds) * time.Second)
	} else if deadline, parseErr := http.ParseTime(value); parseErr == nil {
		err.RetryAfter = deadline
	}
	return err
}

var cooldowns = struct {
	sync.Mutex
	until map[string]time.Time
}{until: map[string]time.Time{}}

func coolHost(host string, until time.Time) {
	cooldowns.Lock()
	defer cooldowns.Unlock()
	now := time.Now()
	for key, value := range cooldowns.until {
		if !value.After(now) {
			delete(cooldowns.until, key)
		}
	}
	if until.After(cooldowns.until[host]) {
		cooldowns.until[host] = until
	}
}

func waitForHost(ctx context.Context, host string) error {
	for {
		cooldowns.Lock()
		remaining := time.Until(cooldowns.until[host])
		if remaining <= 0 {
			delete(cooldowns.until, host)
		}
		cooldowns.Unlock()
		if remaining <= 0 {
			return ctx.Err()
		}
		timer := time.NewTimer(remaining)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

type hostSlots struct {
	slots chan struct{}
	users int
}

var connectionsBudget = struct {
	sync.Mutex
	all   chan struct{}
	hosts map[string]*hostSlots
}{all: make(chan struct{}, 768), hosts: map[string]*hostSlots{}}

// Queued requests do not hold a global slot while their host is saturated.
// Releasing a slot wakes earlier waiters, including other download tasks.
func acquireConnection(ctx context.Context, host string) (func(), error) {
	return acquireHostConnection(ctx, host, 512)
}

func acquireProfileConnection(ctx context.Context, host, profile string) (func(), error) {
	if profile == "xunlei" {
		return acquireXunleiConnection(ctx, host)
	}
	if profile == "guangya" {
		return guangyaHosts.acquire(ctx, host)
	}
	if profile == "aliyun" {
		// Also cover resumed checkpoints with the old, larger number of ranges
		// and simultaneous files using the same Aliyun download host.
		return acquireHostConnection(ctx, "aliyun:"+host, aliyunConnections)
	}
	return acquireConnection(ctx, host)
}

func acquireHostConnection(ctx context.Context, host string, maximum int) (func(), error) {
	connectionsBudget.Lock()
	entry := connectionsBudget.hosts[host]
	if entry == nil {
		entry = &hostSlots{slots: make(chan struct{}, maximum)}
		connectionsBudget.hosts[host] = entry
	}
	entry.users++
	connectionsBudget.Unlock()
	drop := func() {
		connectionsBudget.Lock()
		defer connectionsBudget.Unlock()
		entry.users--
		if entry.users == 0 {
			delete(connectionsBudget.hosts, host)
		}
	}
	select {
	case <-ctx.Done():
		drop()
		return nil, ctx.Err()
	case entry.slots <- struct{}{}:
	}
	select {
	case <-ctx.Done():
		<-entry.slots
		drop()
		return nil, ctx.Err()
	case connectionsBudget.all <- struct{}{}:
	}
	return func() { <-connectionsBudget.all; <-entry.slots; drop() }, nil
}
