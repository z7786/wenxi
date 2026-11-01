// AsterLink queued-start generation tracking, 2026-09-12. Gopeed v1.8.1 / GPL-3.0.
package download

import (
	"encoding/json"
	"github.com/GopeedLab/gopeed/internal/controller"
	"github.com/GopeedLab/gopeed/internal/fetcher"
	"github.com/GopeedLab/gopeed/internal/protocol/bt"
	"github.com/GopeedLab/gopeed/internal/protocol/http"
	"github.com/GopeedLab/gopeed/pkg/base"
	"github.com/GopeedLab/gopeed/pkg/util"
	gonanoid "github.com/matoous/go-nanoid/v2"
	"sync"
	"sync/atomic"
	"time"
)

type ResolveResult struct {
	ID  string         `json:"id"`
	Res *base.Resource `json:"res"`
}

type Task struct {
	ID        string               `json:"id"`
	Protocol  string               `json:"protocol"`
	Meta      *fetcher.FetcherMeta `json:"meta"`
	Status    base.Status          `json:"status"`
	Uploading bool                 `json:"uploading"`
	Progress  *Progress            `json:"progress"`
	CreatedAt time.Time            `json:"createdAt"`
	UpdatedAt time.Time            `json:"updatedAt"`

	fetcherManager fetcher.FetcherManager
	fetcher        fetcher.Fetcher
	timer          *util.Timer
	statusLock     *sync.Mutex
	lock           *sync.Mutex
	downloadRate   transferRate
	uploadRate     transferRate
	runVersion     *atomic.Uint64
	resolution     *resolutionControl
	lastCheckpoint time.Time
}

func NewTask() *Task {
	id, err := gonanoid.New()
	if err != nil {
		panic(err)
	}
	return &Task{
		ID:        id,
		Status:    base.DownloadStatusReady,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
	}
}

// Name returns the display name of the task.
func (t *Task) Name() string {
	// Custom name first
	if t.Meta.Opts.Name != "" {
		return t.Meta.Opts.Name
	}

	// Task is not resolved, parse the name from the URL
	if t.Meta.Res == nil {
		fallbackName := "unknown"
		if t.fetcherManager == nil {
			return fallbackName
		}
		parseName := t.fetcherManager.ParseName(t.Meta.Req.URL)
		if parseName == "" {
			return fallbackName
		}
		return parseName
	}

	// Task is a folder
	if t.Meta.Res.Name != "" {
		return t.Meta.Res.Name
	}

	// Get the name of the first file
	return t.Meta.Res.Files[0].Name
}

func (t *Task) MarshalJSON() ([]byte, error) {
	type rawTaskType Task
	jsonTask := struct {
		rawTaskType
		Name string `json:"name"`
	}{
		rawTaskType(*t),
		t.Name(),
	}
	return json.Marshal(jsonTask)
}

func (t *Task) updateStatus(status base.Status) {
	t.UpdatedAt = time.Now()
	t.Status = status
	if t.Progress != nil && status != base.DownloadStatusRunning {
		t.Progress.Speed = 0
	}
}

func (t *Task) clone() *Task {
	return util.DeepClone(t)
}

type rateSample struct {
	bytes   float64
	elapsed time.Duration
}

// Count only bytes received since the baseline, over actual monotonic time.
// Checkpoint writes and listeners can delay refreshes; the configured sleep
// interval is not the duration covered by a progress delta.
type transferRate struct {
	lastAt    time.Time
	lastBytes int64
	samples   []rateSample
}

func (t *Task) receivedBytes(progress int64) int64 {
	if counter, ok := t.fetcher.(interface{ DownloadedBytes() int64 }); ok {
		return counter.DownloadedBytes()
	}
	return progress
}

func (r *transferRate) reset(total int64, now time.Time) {
	r.lastAt, r.lastBytes = now, total
	r.samples = nil
}

func (r *transferRate) update(total int64, now time.Time) int64 {
	if r.lastAt.IsZero() || total < r.lastBytes {
		r.reset(total, now)
		return 0
	}
	elapsed := now.Sub(r.lastAt)
	if elapsed <= 0 {
		return 0
	}
	r.samples = append(r.samples, rateSample{float64(total - r.lastBytes), elapsed})
	r.lastAt, r.lastBytes = now, total
	var duration time.Duration
	var bytes float64
	for _, sample := range r.samples {
		duration += sample.elapsed
		bytes += sample.bytes
	}
	// Trim the oldest sample proportionally when intervals straddle the window.
	const window = 5 * time.Second
	for duration > window && len(r.samples) > 0 {
		first := &r.samples[0]
		trim := min(duration-window, first.elapsed)
		removed := first.bytes * float64(trim) / float64(first.elapsed)
		bytes -= removed
		duration -= trim
		first.bytes -= removed
		first.elapsed -= trim
		if first.elapsed == 0 {
			r.samples = r.samples[1:]
		}
	}
	return max(0, int64(bytes/duration.Seconds()))
}

type TaskFilter struct {
	IDs         []string
	Statuses    []base.Status
	NotStatuses []base.Status
}

func (f *TaskFilter) IsEmpty() bool {
	return len(f.IDs) == 0 && len(f.Statuses) == 0 && len(f.NotStatuses) == 0
}

type DownloaderConfig struct {
	Controller    *controller.Controller
	FetchManagers []fetcher.FetcherManager

	RefreshInterval   int // RefreshInterval time duration to refresh task progress(ms)
	Storage           Storage
	StorageDir        string
	WhiteDownloadDirs []string

	ProductionMode bool

	*base.DownloaderStoreConfig
}

func (cfg *DownloaderConfig) Init() *DownloaderConfig {
	if cfg.Controller == nil {
		cfg.Controller = controller.NewController()
	}
	if len(cfg.FetchManagers) == 0 {
		cfg.FetchManagers = []fetcher.FetcherManager{
			new(http.FetcherManager),
			new(bt.FetcherManager),
		}
	}
	if cfg.RefreshInterval == 0 {
		cfg.RefreshInterval = 350
	}
	if cfg.Storage == nil {
		cfg.Storage = NewMemStorage()
	}
	return cfg
}
