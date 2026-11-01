package ed2k

import (
	"errors"
	"sync"
	"sync/atomic"

	"github.com/GopeedLab/gopeed/internal/controller"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/engine"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/link"
	"github.com/GopeedLab/gopeed/internal/fetcher"
	"github.com/GopeedLab/gopeed/pkg/base"
)

type Options struct {
	SpeedLimit int64 `json:"speedLimit"`
}
type Fetcher struct {
	runtime             *Runtime
	meta                *fetcher.FetcherMeta
	mu                  sync.Mutex
	progress            engine.Progress
	runID               engine.RunID
	ended               chan struct{}
	done                chan error
	closed              chan struct{}
	closeOnce           sync.Once
	stopping            atomic.Bool
	finishOnce          sync.Once
	bytes               atomic.Int64
	lastNetworkReceived int64
	stopError           error
}

func (f *Fetcher) Setup(_ *controller.Controller) {
	f.done = make(chan error, 1)
	f.closed = make(chan struct{})
	if f.meta == nil {
		f.meta = &fetcher.FetcherMeta{}
	}
}
func (f *Fetcher) Resolve(req *base.Request) error {
	file, err := link.Parse(req.URL)
	if err != nil {
		return err
	}
	f.meta.Req = req
	f.meta.Res = &base.Resource{Size: file.Size, Hash: file.Hash.String(), Range: true, Files: []*base.FileInfo{{Name: file.Name, Size: file.Size}}}
	return nil
}
func (f *Fetcher) Create(opts *base.Options) error {
	if err := base.ParseOptsExtra[Options](opts); err != nil {
		return err
	}
	f.meta.Opts = opts
	return nil
}
func (f *Fetcher) Start() error {
	if f.meta.Req == nil || f.meta.Opts == nil {
		return errors.New("ED2K task is not initialized")
	}
	if err := base.ParseOptsExtra[Options](f.meta.Opts); err != nil {
		return err
	}
	limit := int64(0)
	if f.meta.Opts.Extra != nil {
		limit = f.meta.Opts.Extra.(*Options).SpeedLimit
	}
	f.mu.Lock()
	f.progress = engine.Progress{}
	f.lastNetworkReceived = 0
	f.stopError = nil
	f.finishOnce = sync.Once{}
	f.ended = make(chan struct{})
	f.stopping.Store(false)
	f.mu.Unlock()
	err := f.runtime.start(f, f.meta.Req.URL, f.meta.SingleFilepath(), limit)
	return err
}
func (f *Fetcher) Pause() error {
	f.stopping.Store(true)
	return f.runtime.stop(f)
}
func (f *Fetcher) Close() error {
	err := f.Pause()
	f.closeOnce.Do(func() { close(f.closed) })
	return err
}
func (f *Fetcher) Wait() error {
	select {
	case err := <-f.done:
		return err
	case <-f.closed:
		return errors.New("ED2K transfer closed")
	}
}
func (f *Fetcher) Meta() *fetcher.FetcherMeta { return f.meta }
func (f *Fetcher) Progress() fetcher.Progress {
	f.mu.Lock()
	defer f.mu.Unlock()
	return fetcher.Progress{f.progress.Received}
}
func (f *Fetcher) ConnectionCounts() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.progress.ActivePeers, f.progress.Peers
}
func (f *Fetcher) DownloadedBytes() int64 { return f.bytes.Load() }
func (f *Fetcher) Stats() any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.progress
}
func (f *Fetcher) setProgress(p engine.Progress) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if p.NetworkReceived > f.lastNetworkReceived {
		f.bytes.Add(p.NetworkReceived - f.lastNetworkReceived)
	}
	f.lastNetworkReceived = p.NetworkReceived
	f.progress = p
}
func (f *Fetcher) finish(err *engine.Error) {
	f.finishOnce.Do(func() {
		var result error
		if err != nil {
			result = err
		}
		// Gopeed keeps its watcher across Pause/Start. Only completion or
		// failure wakes it; replacing its channel strands that watcher.
		if !f.stopping.Load() {
			f.done <- result
		} else if result != nil {
			f.mu.Lock()
			f.stopError = result
			f.mu.Unlock()
		}
		close(f.ended)
	})
}

type fetcherData struct{ Received int64 }
type FetcherManager struct{ Runtime *Runtime }

func (m *FetcherManager) Name() string { return "ed2k" }
func (m *FetcherManager) Filters() []*fetcher.SchemeFilter {
	return []*fetcher.SchemeFilter{{Type: fetcher.FilterTypeUrl, Pattern: "ED2K"}}
}
func (m *FetcherManager) Build() fetcher.Fetcher      { return &Fetcher{runtime: m.Runtime} }
func (m *FetcherManager) ParseName(url string) string { file, _ := link.Parse(url); return file.Name }
func (m *FetcherManager) AutoRename() bool            { return false }
func (m *FetcherManager) DefaultConfig() any          { return &struct{}{} }
func (m *FetcherManager) Store(source fetcher.Fetcher) (any, error) {
	return &fetcherData{Received: source.Progress().TotalDownloaded()}, nil
}
func (m *FetcherManager) Restore() (any, func(*fetcher.FetcherMeta, any) fetcher.Fetcher) {
	return &fetcherData{}, func(meta *fetcher.FetcherMeta, data any) fetcher.Fetcher {
		return &Fetcher{runtime: m.Runtime, meta: meta, progress: engine.Progress{Received: data.(*fetcherData).Received}}
	}
}
func (m *FetcherManager) Close() error { return m.Runtime.Close() }
