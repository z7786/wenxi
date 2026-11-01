package download

// AsterLink integration additions, 2026-09-12. Upstream: Gopeed v1.8.1 (GPL-3.0).
// Android must not delete/export a payload while an asynchronous Pause is still writing it.
import (
	"context"
	corebt "github.com/GopeedLab/gopeed/internal/protocol/bt"
	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
	"sync"
)

type resolutionControl struct {
	mu     sync.Mutex
	cancel context.CancelFunc
}

// ConnectionCounts is safe to call while the progress listener already holds
// the task's status lock. HTTP fetchers publish atomic, transient counters.
func (t *Task) ConnectionCounts() (active, total int) {
	if counters, ok := t.fetcher.(interface{ ConnectionCounts() (int, int) }); ok {
		return counters.ConnectionCounts()
	}
	return 0, 0
}

func (t *Task) BTSourceState() *corebt.SourceState {
	if source, ok := t.fetcher.(interface{ BTSourceState() *corebt.SourceState }); ok {
		return source.BTSourceState()
	}
	return nil
}

func (t *Task) AliyunTransferState() *fhttp.AliyunTransferState {
	if source, ok := t.fetcher.(interface {
		AliyunTransferState() *fhttp.AliyunTransferState
	}); ok {
		return source.AliyunTransferState()
	}
	return nil
}

func (t *Task) ReadableRanges() [][2]int64 {
	if source, ok := t.fetcher.(interface{ ReadableRanges() [][2]int64 }); ok {
		return source.ReadableRanges()
	}
	return nil
}

func (t *Task) cancelResolve() {
	t.resolution.mu.Lock()
	defer t.resolution.mu.Unlock()
	if t.resolution.cancel != nil {
		t.resolution.cancel()
	}
}

func (t *Task) resolveForRun(version uint64) error {
	resolver, ok := t.fetcher.(interface {
		ResolveContext(context.Context, *base.Request) error
	})
	if !ok {
		return t.fetcher.Resolve(t.Meta.Req)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.resolution.mu.Lock()
	if t.runVersion.Load() != version {
		cancel()
	}
	t.resolution.cancel = cancel
	t.resolution.mu.Unlock()
	defer func() {
		cancel()
		t.resolution.mu.Lock()
		t.resolution.cancel = nil
		t.resolution.mu.Unlock()
	}()
	return resolver.ResolveContext(ctx, t.Meta.Req)
}

func (d *Downloader) PauseAndSave(id string) error {
	task := d.GetTask(id)
	if task == nil {
		return ErrTaskNotFound
	}
	task.statusLock.Lock()
	defer task.statusLock.Unlock()
	task.runVersion.Add(1)
	task.cancelResolve()
	task.lock.Lock()
	defer task.lock.Unlock()
	if task.Status == base.DownloadStatusDone {
		// Direct output leases may be closed or rebound after this call. BT
		// still owns a torrent client and an upload watcher after completion.
		// Finish both before the caller releases its output descriptor.
		if task.fetcher != nil {
			return task.fetcher.Close()
		}
		return nil
	}
	task.updateStatus(base.DownloadStatusPause)
	task.timer.Pause()
	if task.fetcher != nil {
		if err := task.fetcher.Pause(); err != nil {
			return err
		}
		task.Progress.Downloaded = task.fetcher.Progress().TotalDownloaded()
		task.Progress.Speed = 0
		if err := d.saveTask(task); err != nil {
			return err
		}
	} else if err := d.storage.Put(bucketTask, task.ID, task.clone()); err != nil {
		return err
	}
	d.emit(EventKeyPause, task)
	return nil
}

// Replace only the request after the Android caller has verified the remote identity.
// Keeping the fetcher's range state avoids losing progress when a signed URL expires.
func (d *Downloader) ReplacePausedRequest(id string, req *base.Request, connectionProfile string, routeOptions ...*fhttp.OptsExtra) error {
	task := d.GetTask(id)
	if task == nil {
		return ErrTaskNotFound
	}
	task.lock.Lock()
	defer task.lock.Unlock()
	if task.Status == base.DownloadStatusDone {
		return nil
	}
	if err := base.ParseReqExtra[fhttp.ReqExtra](req); err != nil {
		return err
	}
	// Upgrade old Baidu checkpoints without discarding their completed ranges.
	// Other providers retain the options captured when the task was created.
	if (connectionProfile == "baidu" || connectionProfile == "baidu_preview" || connectionProfile == "baidu_direct") && len(routeOptions) == 1 && routeOptions[0] != nil {
		if err := base.ParseOptsExtra[fhttp.OptsExtra](task.Meta.Opts); err != nil {
			return err
		}
		if task.Meta.Opts.Extra == nil {
			task.Meta.Opts.Extra = &fhttp.OptsExtra{}
		}
		extra := task.Meta.Opts.Extra.(*fhttp.OptsExtra)
		extra.Connections = max(1, min(512, routeOptions[0].Connections))
		if limit := fhttp.BaiduConnectionLimit(connectionProfile); limit > 0 {
			extra.Connections = min(extra.Connections, limit)
		}
		extra.ConnectionProfile = connectionProfile
		if task.fetcher != nil {
			task.fetcher.Meta().Opts = task.Meta.Opts
		}
	}
	if connectionProfile == "baidu_public" && len(routeOptions) == 1 && routeOptions[0] != nil {
		if err := base.ParseOptsExtra[fhttp.OptsExtra](task.Meta.Opts); err != nil {
			return err
		}
		if task.Meta.Opts.Extra == nil {
			task.Meta.Opts.Extra = &fhttp.OptsExtra{}
		}
		extra := task.Meta.Opts.Extra.(*fhttp.OptsExtra)
		extra.ConnectionProfile = "baidu_public"
		extra.Connections = max(1, min(512, routeOptions[0].Connections))
		if task.fetcher != nil {
			task.fetcher.Meta().Opts = task.Meta.Opts
		}
	}
	if connectionProfile == "aliyun" && len(routeOptions) == 1 && routeOptions[0] != nil {
		if err := base.ParseOptsExtra[fhttp.OptsExtra](task.Meta.Opts); err != nil {
			return err
		}
		if task.Meta.Opts.Extra == nil {
			task.Meta.Opts.Extra = &fhttp.OptsExtra{}
		}
		extra := task.Meta.Opts.Extra.(*fhttp.OptsExtra)
		extra.ConnectionProfile = "aliyun"
		extra.Connections = max(1, min(8, routeOptions[0].Connections))
		extra.AliyunGroup = routeOptions[0].AliyunGroup
		if task.fetcher != nil {
			task.fetcher.Meta().Opts = task.Meta.Opts
			if policy, ok := task.fetcher.(interface{ PrepareAliyunTransfer(string, int) }); ok {
				policy.PrepareAliyunTransfer(extra.AliyunGroup, extra.Connections)
			}
		}
	}
	task.Meta.Req = req
	if task.fetcher != nil {
		task.fetcher.Meta().Req = req
	}
	return d.storage.Put(bucketTask, task.ID, task.clone())
}
