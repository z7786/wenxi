package btpolicy

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/anacrolix/torrent/bencode"
)

// Probe transport availability without announcing any user's torrent. A UDP
// BEP15 connect packet does not contain an infohash, account or file identity.
// HTTP probes use scrape with no hash; unsupported scrape responses are retried
// later rather than installed as a known-good supplemental tracker.
type trackerHealth struct {
	until   time.Time
	healthy bool
}

var trackerCache = struct {
	sync.Mutex
	rows map[string]trackerHealth
}{rows: map[string]trackerHealth{}}

func trackerAvailable(ctx context.Context, address string) bool {
	trackerCache.Lock()
	row, ok := trackerCache.rows[address]
	trackerCache.Unlock()
	if ok && row.until.After(time.Now()) {
		return row.healthy
	}
	healthy := probeTracker(ctx, address) == nil
	if errors.Is(ctx.Err(), context.Canceled) {
		return false
	}
	lifetime := 10 * time.Minute
	if healthy {
		lifetime = 6 * time.Hour
	}
	trackerCache.Lock()
	trackerCache.rows[address] = trackerHealth{until: time.Now().Add(lifetime), healthy: healthy}
	trackerCache.Unlock()
	return healthy
}

func probeTracker(ctx context.Context, address string) error {
	u, err := url.Parse(address)
	if err != nil {
		return err
	}
	if u.Scheme == "udp" {
		conn, err := (&net.Dialer{}).DialContext(ctx, "udp", u.Host)
		if err != nil {
			return err
		}
		defer conn.Close()
		stop := context.AfterFunc(ctx, func() { conn.Close() })
		defer stop()
		deadline, _ := ctx.Deadline()
		_ = conn.SetDeadline(deadline)
		request := make([]byte, 16)
		binary.BigEndian.PutUint64(request, 0x41727101980)
		if _, err = rand.Read(request[12:]); err != nil {
			return err
		}
		if _, err = conn.Write(request); err != nil {
			return err
		}
		response := make([]byte, 2048)
		n, err := conn.Read(response)
		if err != nil {
			return err
		}
		if n != 16 || binary.BigEndian.Uint32(response[:4]) != 0 || binary.BigEndian.Uint32(response[4:8]) != binary.BigEndian.Uint32(request[12:]) {
			return errors.New("invalid tracker connect response")
		}
		return nil
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return errors.New("unsupported tracker")
	}
	u.Path = "/scrape"
	request, err := http.NewRequestWithContext(ctx, "GET", u.String(), nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return errors.New("tracker unavailable")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil || len(body) > 65536 {
		return errors.New("invalid tracker response")
	}
	var value map[string]any
	if bencode.Unmarshal(body, &value) != nil {
		return errors.New("invalid tracker response")
	}
	if _, ok := value["files"].(map[string]any); !ok {
		return errors.New("tracker scrape unsupported")
	}
	return nil
}
