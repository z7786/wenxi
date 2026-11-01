// AsterLink's embedded Kelpie runtime. State uses the existing encrypted
// Gopeed store; payloads use the same caller-owned outputs as HTTP and BT.
package ed2k

import (
	"errors"
	"io/fs"
	"net/netip"
	"os"
	"path/filepath"
	"sync"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/disk"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/engine"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/server"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/outputfile"
)

type StateStorage interface {
	Get(bucket, key string, out any) (bool, error)
	Put(bucket, key string, value any) error
}

type Runtime struct {
	lifecycle sync.Mutex
	mu        sync.Mutex
	core      *engine.Engine
	next      engine.RunID
	runs      map[engine.RunID]*Fetcher
	storage   StateStorage
	folder    string
	servers   []server.Entry
	network   engine.Network
	settings  engine.Settings
}

// NewRuntime does no network work until the first ED2K task starts.
func NewRuntime(folder string, storage StateStorage) *Runtime {
	return &Runtime{folder: folder, storage: storage, runs: map[engine.RunID]*Fetcher{}, servers: defaultServers(),
		settings: engine.Settings{EnableKad: true, EnableUPnP: true, UploadLimit: 128 * 1024}}
}

func defaultServers() []server.Entry {
	var entries []server.Entry
	// eMule Security / eMule Sunrise bootstrap servers. Learned addresses and
	// Kad contacts are retained; sources in an ED2K link also work directly.
	for _, address := range []string{"176.123.5.89:4725", "45.82.80.155:5687", "5.45.85.226:6584"} {
		entries = append(entries, server.Entry{Endpoint: netip.MustParseAddrPort(address)})
	}
	return entries
}

func (r *Runtime) load() (store.State, error) {
	var raw []byte
	_, err := r.storage.Get("ed2k", "state", &raw)
	if err != nil {
		return store.State{}, err
	}
	return store.Decode(raw)
}
func (r *Runtime) save(state store.State) error {
	raw, err := store.Encode(state)
	if err != nil {
		return err
	}
	return r.storage.Put("ed2k", "state", raw)
}

func (r *Runtime) start(f *Fetcher, url, path string, limit int64) error {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	r.mu.Lock()
	busy := len(r.runs) > 0
	r.mu.Unlock()
	if busy {
		return errors.New("another ED2K transfer is active")
	}
	settings := r.settings
	settings.DownloadLimit = limit
	if r.core == nil {
		core, err := engine.Start(engine.Config{
			Version: "AsterLink 2.0", DataFolder: r.folder, Port: 0,
			Disk: outputDisk{}, LoadState: r.load, SaveState: r.save, Servers: r.servers,
			Settings: settings,
		}, r)
		if err != nil {
			return err
		}
		r.core = core
	} else {
		r.core.Post(settings)
	}
	r.next++
	f.runID = r.next
	r.mu.Lock()
	r.runs[f.runID] = f
	r.mu.Unlock()
	r.core.Post(engine.RunCommand{ID: f.runID, Mode: engine.ModeDownload, Link: url, File: path})
	return nil
}

func (r *Runtime) stop(f *Fetcher) error {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	if r.core == nil || f.runID == 0 {
		return nil
	}
	r.core.Post(engine.StopCommand{ID: f.runID})
	<-f.ended
	f.mu.Lock()
	stopErr := f.stopError
	f.mu.Unlock()
	r.mu.Lock()
	delete(r.runs, f.runID)
	f.runID = 0
	last := len(r.runs) == 0
	r.mu.Unlock()
	if last {
		err := r.core.Close()
		r.core = nil
		return errors.Join(stopErr, err)
	}
	reply := make(chan error, 1)
	r.core.Post(engine.CheckpointCommand{Reply: reply})
	return errors.Join(stopErr, <-reply)
}

func (r *Runtime) Close() error {
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	if r.core == nil {
		return nil
	}
	err := r.core.Close()
	r.core = nil
	r.mu.Lock()
	r.runs = map[engine.RunID]*Fetcher{}
	r.mu.Unlock()
	return err
}

func (r *Runtime) Forget(hash, path string) error {
	h, err := wire.ParseHash(hash)
	if err != nil {
		return err
	}
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	r.mu.Lock()
	for _, active := range r.runs {
		if active.meta.Res.Hash == hash && filepath.Clean(active.meta.SingleFilepath()) != filepath.Clean(path) {
			r.mu.Unlock()
			return nil // Deleting older completed history must not stop a new run.
		}
	}
	r.mu.Unlock()
	if r.core != nil {
		reply := make(chan error, 1)
		r.core.Post(engine.CheckpointCommand{Reply: reply})
		if err := <-reply; err != nil {
			return err
		}
	}
	state, err := r.load()
	if err != nil {
		return err
	}
	transfer, ok := state.Transfers[h]
	if !ok || filepath.Clean(transfer.File) != filepath.Clean(path) {
		return nil
	}
	if r.core != nil {
		r.core.Post(engine.RemoveCommand{Hash: h})
		reply := make(chan error, 1)
		r.core.Post(engine.CheckpointCommand{Reply: reply})
		return <-reply
	}
	delete(state.Transfers, h)
	return r.save(state)
}

func (r *Runtime) HasResume(hash, path string, size, available int64) (bool, error) {
	h, err := wire.ParseHash(hash)
	if err != nil {
		return false, err
	}
	r.lifecycle.Lock()
	defer r.lifecycle.Unlock()
	if r.core != nil {
		reply := make(chan error, 1)
		r.core.Post(engine.CheckpointCommand{Reply: reply})
		if err := <-reply; err != nil {
			return false, err
		}
	}
	state, err := r.load()
	if err != nil {
		return false, err
	}
	transfer, ok := state.Transfers[h]
	if !ok || filepath.Clean(transfer.File) != filepath.Clean(path) || transfer.Size != size {
		return false, nil
	}
	for i, verified := range transfer.VerifiedParts {
		if verified && piece.PartRange(size, i).End > available {
			return false, nil
		}
	}
	for _, block := range transfer.WrittenBlocks {
		if block.End > available {
			return false, nil
		}
	}
	return true, nil
}

func (r *Runtime) SetProgress(id engine.RunID, p engine.Progress) {
	r.mu.Lock()
	f := r.runs[id]
	r.mu.Unlock()
	if f != nil {
		f.setProgress(p)
	}
}
func (r *Runtime) SendEnded(id engine.RunID, err *engine.Error) {
	r.mu.Lock()
	f := r.runs[id]
	r.mu.Unlock()
	if f != nil {
		f.finish(err)
	}
}
func (r *Runtime) SetNetwork(network engine.Network) {
	r.mu.Lock()
	r.network = network
	r.mu.Unlock()
}

// Every writer holds the file lock. Close drains current I/O and rejects
// queued disk jobs, so Pause never returns while an output is still writable.
type lockedFile struct {
	sync.RWMutex
	file   *os.File
	closed bool
}

func (f *lockedFile) ReadAt(b []byte, off int64) (int, error) {
	f.RLock()
	defer f.RUnlock()
	if f.closed {
		return 0, os.ErrClosed
	}
	return f.file.ReadAt(b, off)
}
func (f *lockedFile) WriteAt(b []byte, off int64) (int, error) {
	f.RLock()
	defer f.RUnlock()
	if f.closed {
		return 0, os.ErrClosed
	}
	return f.file.WriteAt(b, off)
}
func (f *lockedFile) Sync() error {
	f.RLock()
	defer f.RUnlock()
	if f.closed {
		return os.ErrClosed
	}
	return f.file.Sync()
}
func (f *lockedFile) Close() error {
	f.Lock()
	defer f.Unlock()
	if f.closed {
		return nil
	}
	f.closed = true
	return errors.Join(f.file.Sync(), f.file.Close())
}

type outputDisk struct{}

func (outputDisk) Open(path string, mode disk.Mode) (disk.File, error) {
	flag := os.O_RDWR | os.O_CREATE
	if mode == disk.Read {
		flag = os.O_RDONLY
	}
	file, err := outputfile.OpenFile(path, flag, 0600)
	if err != nil {
		return nil, err
	}
	if mode != disk.Read {
		prepareOutput(file)
	}
	return &lockedFile{file: file}, nil
}
func (outputDisk) Probe(path string) (*disk.Info, error) {
	info, err := outputfile.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &disk.Info{Size: info.Size(), IsFolder: info.IsDir()}, nil
}
