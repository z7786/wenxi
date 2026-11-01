package http

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestSmallFileConnectionBudget(t *testing.T) {
	for _, c := range []struct {
		size             int64
		configured, want int
	}{
		{0, 512, 1}, {256 * 1024, 512, 1}, {1024 * 1024, 512, 4},
		{128 * 1024 * 1024, 512, 512}, {1024 * 1024, 2, 2},
	} {
		if got := effectiveConnections(c.size, c.configured, ""); got != c.want {
			t.Fatalf("size=%d configured=%d got=%d want=%d", c.size, c.configured, got, c.want)
		}
	}
}

func TestBaiduAccountConnectionBudget(t *testing.T) {
	for _, configured := range []int{1, 64, 512} {
		if got := effectiveConnections(2*1024*1024*1024, configured, "baidu"); got != configured {
			t.Fatalf("configured=%d got=%d", configured, got)
		}
	}
}

func TestBaiduPreviewConnectionBudget(t *testing.T) {
	for _, c := range []struct {
		size             int64
		configured, want int
	}{
		{0, 512, 1}, {4096, 512, 1}, {1024 * 1024, 512, 4},
		{2 * 1024 * 1024 * 1024, 512, 512}, {1024 * 1024, 1, 1},
	} {
		if got := effectiveConnections(c.size, c.configured, "baidu_preview"); got != c.want {
			t.Fatalf("%+v got=%d", c, got)
		}
	}
}

func TestQuarkConnectionBudget(t *testing.T) {
	for _, c := range []struct {
		size       int64
		configured int
		profile    string
		want       int
	}{
		{40_000_000, 512, "quark_route_1", 512},
		{40 * 1024 * 1024, 512, "quark_route_1", 512},
		{40 * 1024 * 1024, 64, "quark_route_1", 64},
		{4096, 512, "quark_route_1", 1},
		{256 * 1024, 512, "quark_route_1", 4},
		{1024 * 1024, 512, "quark_route_1", 16},
		{40 * 1024 * 1024, 512, "quark_route_2", 160},
		{40 * 1024 * 1024, 512, "uc", 160},
		{40 * 1024 * 1024, 64, "xunlei", 64},
		{40 * 1024 * 1024, 512, "xunlei", 160},
		{40 * 1024 * 1024, 512, "unknown", 160},
		{1<<63 - 1, 512, "quark_route_1", 512},
		{0, 512, "quark_route_1", 1},
	} {
		if got := effectiveConnections(c.size, c.configured, c.profile); got != c.want {
			t.Fatalf("%+v got=%d", c, got)
		}
	}
}

func TestAliyunConnectionBudget(t *testing.T) {
	for _, c := range []struct {
		size             int64
		configured, want int
	}{
		{2 * 1024 * 1024 * 1024, 64, 8},
		{2 * 1024 * 1024 * 1024, 512, 8},
		{2 * 1024 * 1024 * 1024, 4, 4},
		{2 * 1024 * 1024 * 1024, 1, 1},
		{512 * 1024, 64, 2},
		{0, 64, 1},
	} {
		if got := effectiveConnections(c.size, c.configured, "aliyun"); got != c.want {
			t.Fatalf("%+v got=%d", c, got)
		}
	}
}

func TestRetryDelay(t *testing.T) {
	for attempt, want := range []time.Duration{2 * time.Second, 5 * time.Second, 10 * time.Second} {
		if got := retryDelay(attempt); got != want {
			t.Fatalf("attempt=%d got=%s want=%s", attempt, got, want)
		}
	}
	if got := retryDelay(99); got != 10*time.Second {
		t.Fatalf("later retry got=%s", got)
	}
}

func TestRetryAfterAndCancellableCooldown(t *testing.T) {
	before := time.Now()
	failure := responseError(&http.Response{StatusCode: 429, Header: http.Header{"Retry-After": {"5"}}})
	if failure.RetryAfter.Before(before.Add(5 * time.Second)) {
		t.Fatal("Retry-After was shortened")
	}
	host := "cooldown-test.invalid"
	coolHost(host, failure.RetryAfter)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if waitForHost(ctx, host) == nil {
		t.Fatal("cancelled cooldown succeeded")
	}
	if time.Since(before) > time.Second {
		t.Fatal("cooldown cancellation was not prompt")
	}
	cooldowns.Lock()
	delete(cooldowns.until, host)
	cooldowns.Unlock()
}

func TestConnectionBudgetCancellationReleasesWaiter(t *testing.T) {
	const host = "budget-test.invalid"
	releases := []func(){}
	for i := 0; i < 512; i++ {
		release, err := acquireConnection(context.Background(), host)
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, release)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if release, err := acquireConnection(ctx, host); err == nil {
		release()
		t.Fatal("host budget exceeded")
	}
	for _, release := range releases {
		release()
	}
	connectionsBudget.Lock()
	defer connectionsBudget.Unlock()
	if _, exists := connectionsBudget.hosts[host]; exists {
		t.Fatal("host bookkeeping leaked")
	}
}

func TestAliyunQueuedRangesShareHostBudgetAndCancel(t *testing.T) {
	const host = "aliyun-budget-test.invalid"
	releases := []func(){}
	for i := 0; i < 8; i++ {
		release, err := acquireProfileConnection(context.Background(), host, "aliyun")
		if err != nil {
			t.Fatal(err)
		}
		releases = append(releases, release)
	}
	defer func() {
		for _, release := range releases {
			release()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if release, err := acquireProfileConnection(ctx, host, "aliyun"); err == nil {
		release()
		t.Fatal("a queued/resumed Aliyun range exceeded the host budget")
	}
	// An unrelated download must not queue behind this provider's host window.
	release, err := acquireProfileConnection(context.Background(), "other.invalid", "quark_route_1")
	if err != nil {
		t.Fatal(err)
	}
	release()
	releases[0]()
	releases = releases[1:]
	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	release, err = acquireProfileConnection(ctx, host, "aliyun")
	if err != nil {
		t.Fatal("cancelled waiter leaked a slot")
	}
	release()
}
