package bt

import (
	"errors"
	"strconv"
	"time"

	"github.com/GopeedLab/gopeed/internal/btpolicy"
	"github.com/GopeedLab/gopeed/pkg/base"
	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

// Only a completed AsterLink task can donate a session. Paused files always
// reopen and rehash. The idle session has no access to any output descriptor.
var warmSessionLifetime = 30 * time.Second

const sessionPathLabel = "asterlinkBTPath"

type warmSession struct {
	torrent *torrent.Torrent
	storage *fileTorrentImpl
	timer   *time.Timer
	claimed bool
}

var warm *warmSession // guarded by lock

func dropWarmLocked() {
	if warm == nil {
		return
	}
	w := warm
	warm = nil
	w.timer.Stop()
	btpolicy.Remember(w.torrent)
	w.torrent.Drop()
}

func takeWarm(req *base.Request, mi *metainfo.MetaInfo) (*torrent.Torrent, bool) {
	lock.Lock()
	defer lock.Unlock()
	if warm == nil {
		return nil, false
	}
	if warm.torrent.InfoHash() != mi.HashInfoBytes() || req.Labels[sessionPathLabel] == "" || req.Labels["asterlinkBTRecheck"] != "" {
		dropWarmLocked()
		return nil, false
	}
	w := warm
	warm = nil
	w.timer.Stop()
	w.storage.resetForSession(req.Labels[sessionPathLabel])
	// No old completion bit can authorize a new task's output. Losing earlier
	// pieces is normal after exporting; peers and tracker connections survive.
	for i := 0; i < w.torrent.NumPieces(); i++ {
		w.torrent.Piece(i).UpdateCompletion()
	}
	// A late chunk may have dirtied a cancelled piece before storage froze.
	// Verify those bounded partial pieces so they cannot suppress fresh reads.
	for i := 0; i < w.torrent.NumPieces(); i++ {
		if w.torrent.PieceState(i).Partial {
			w.torrent.Piece(i).VerifyData()
		}
	}
	return w.torrent, true
}

func (f *Fetcher) parkCompleted() bool {
	if f.meta == nil || f.meta.Req == nil || f.meta.Req.Labels[sessionPathLabel] == "" || !f.isDone() {
		return false
	}
	t := f.torrent
	t.DisallowDataDownload()
	t.DisallowDataUpload()
	for _, file := range t.Files() {
		file.SetPriority(torrent.PiecePriorityNone)
	}
	t.CancelPieces(0, t.NumPieces())
	lock.Lock()
	defer lock.Unlock()
	ft := ftMap[t.InfoHash().String()]
	if ft == nil {
		return false
	}
	ft.freeze()
	// A hash may have released its read handle before marking completion. Wait
	// for marking too, so the caller can move/delete/close the old output safely.
	deadline := time.Now().Add(3 * time.Second)
	for {
		busy := false
		for _, state := range t.PieceStateRuns() {
			if state.Checking || state.Marking {
				busy = true
				break
			}
		}
		if !busy {
			break
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(5 * time.Millisecond)
	}
	dropWarmLocked()
	w := &warmSession{torrent: t, storage: ft}
	warm = w
	w.timer = time.AfterFunc(warmSessionLifetime, func() {
		lock.Lock()
		defer lock.Unlock()
		if warm != w || w.claimed {
			return
		}
		warm = nil
		btpolicy.Remember(t)
		t.Drop()
		if client != nil && len(client.Torrents()) == 0 {
			_ = closeClientLocked()
		}
	})
	return true
}

func (ft *fileTorrentImpl) freeze() {
	ft.ioMu.Lock()
	ft.frozen = true
	ft.ioMu.Unlock()
}

func (ft *fileTorrentImpl) resetForSession(dir string) {
	ft.ioMu.Lock()
	defer ft.ioMu.Unlock()
	ft.completion = storage.NewMapPieceCompletion()
	ft.setTorrentDirLocked(dir)
	ft.frozen = false
}

// Useful payload sources include native peers and webseeds. Counts are read
// through the library's synchronized snapshots, never KnownSwarm's maps.
type SourceState struct {
	Connected     int   `json:"connected"`
	Known         int   `json:"known"`
	Seeders       int   `json:"seeders"`
	Webseeds      int   `json:"webseeds"`
	Trackers      int   `json:"trackers"`
	UploadLimit   int64 `json:"uploadLimit"`
	SessionReused bool  `json:"sessionReused"`
}

func (f *Fetcher) BTSourceState() *SourceState {
	if !f.torrentReady.Load() {
		return nil
	}
	s := f.torrentStats()
	limit := f.meta.Req.Labels["asterlinkBTUploadLimit"]
	bytes, _ := strconv.ParseInt(limit, 10, 64)
	return &SourceState{Connected: s.ActivePeers, Known: s.TotalPeers, Seeders: s.ConnectedSeeders,
		Webseeds: len(f.torrent.WebseedPeerConns()), Trackers: trackerCount(f.torrent), UploadLimit: bytes, SessionReused: f.sessionReused}
}

func trackerCount(t *torrent.Torrent) int {
	count := 0
	for _, tier := range t.Metainfo().AnnounceList {
		count += len(tier)
	}
	return count
}

func (f *Fetcher) ConnectionCounts() (int, int) {
	if !f.torrentReady.Load() {
		return 0, 0
	}
	s := f.torrentStats()
	return s.ActivePeers, s.TotalPeers
}

var errFrozen = errors.New("BT output released")

// A cancelled request can still arrive after the old output has been released.
// Reject its write without letting the library disable a subsequently resumed
// session. Genuine storage failures retain the default stop-download behavior.
func sessionWriteError(t *torrent.Torrent, err error) {
	if !errors.Is(err, errFrozen) {
		t.DisallowDataDownload()
	}
}
