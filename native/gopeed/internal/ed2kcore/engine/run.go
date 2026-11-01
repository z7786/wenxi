package engine

import (
	"maps"
	"reflect"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/aich"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/disk"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/link"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/peer"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transfer"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

// run is one open Run. transfer is nil while a seed's file is being
// checked against the link.
type run struct {
	id       RunID
	mode     Mode
	file     link.File
	path     string
	handle   disk.File
	transfer *transfer.Transfer
	share    peer.Share
	progress Progress
	// asked maps each user we sent the file request to the last time we did.
	asked map[wire.Hash]time.Time
	// isSyncing is set while a complete download is flushed to the device;
	// the run ends when that is done.
	isSyncing bool
	// tree is the AICH tree of a complete file, nil until hashed.
	tree          *aich.Tree
	isTreeHashing bool
}

// fileReaskTime is aMule's FILEREASKTIME (Constants.h:35), the transfer's
// reask interval.
const fileReaskTime = 1300 * time.Second

// stoppedRun is what an ended download Run leaves for the next Run of its
// file: the stopped Transfer, which holds the sources and when each is due,
// and asked. Without it a Run opened after a stop would know no source until
// the server or Kad, which pace their searches per file, found them again,
// and would ask the sources it finds sooner than eMule does. It is no
// paused state (ADR-0004): nothing resumes it, and it ends with the Engine
// Process, with remove, with the next Run of the file, or after
// stoppedTime.
type stoppedRun struct {
	transfer *transfer.Transfer
	asked    map[wire.Hash]time.Time
	at       time.Time
}

// stoppedTime is how long a stopped Run's sources are kept: aMule drops the
// sources of a file paused for an hour (CPartFile::StopPausedFile,
// PartFile.cpp:2780-2797).
const stoppedTime = time.Hour

func (e *Engine) onCommand(command Command) {
	switch c := command.(type) {
	case RunCommand:
		if err := e.startRun(c); err != nil {
			e.events.SendEnded(c.ID, err)
		}
	case StopCommand:
		if r := e.runByID(c.ID); r != nil {
			e.stopRun(r, nil)
		}
	case RemoveCommand:
		if r := e.runByHash[c.Hash]; r != nil {
			e.stopRun(r, nil)
		}
		delete(e.stopped, c.Hash)
		if _, ok := e.state.Transfers[c.Hash]; ok {
			delete(e.state.Transfers, c.Hash)
			e.requestSave()
		}
	case Settings:
		e.update(c)
	case CheckpointCommand:
		c.Reply <- e.checkpoint()
	}
}

// startRun admits a run per docs/protocol.md "Run rules".
func (e *Engine) startRun(c RunCommand) *Error {
	file, err := link.Parse(c.Link)
	if err != nil {
		return &Error{Code: CodeInvalidLink, Message: err.Error()}
	}
	if e.runByHash[file.Hash] != nil {
		return &Error{Code: CodeTransferBusy, Message: "another run is open for " + file.Hash.String()}
	}
	r := &run{id: c.ID, mode: c.Mode, file: file, path: c.File, asked: map[wire.Hash]time.Time{}}
	var state *transfer.State
	if old, ok := e.state.Transfers[file.Hash]; ok && old.File == c.File && old.Size == file.Size {
		resume := transfer.State(old)
		state = &resume
	}
	info, err := e.ports.Disk.Probe(c.File)
	if err != nil {
		return toFileError(err)
	}

	if c.Mode == ModeSeed {
		if info == nil || info.IsFolder || info.Size != file.Size {
			return &Error{Code: CodeFileError, Message: c.File + " is not the complete file of the link"}
		}
		if r.handle, err = e.ports.Disk.Open(c.File, disk.Read); err != nil {
			return toFileError(err)
		}
		e.addRun(r)
		if state != nil && isComplete(state) {
			e.startTransfer(r, state, nil)
		} else {
			e.disk.send(diskJob{kind: jobHashFile, run: r.id, file: r.handle, block: piece.Block{End: file.Size}})
		}
		e.refreshProgress(r, true)
		return nil
	}

	if info != nil && state == nil && (info.IsFolder || info.Size > 0) {
		return &Error{Code: CodeOutputExists, Message: c.File + " already exists"}
	}
	// Resume data for a file that is gone would claim blocks it no longer has.
	if info == nil {
		state = nil
	}
	if r.handle, err = e.ports.Disk.Open(c.File, disk.Create); err != nil {
		return toFileError(err)
	}
	var previous *transfer.Transfer
	if stopped, ok := e.stopped[file.Hash]; ok {
		previous, r.asked = stopped.transfer, stopped.asked
	}
	e.addRun(r)
	e.startTransfer(r, state, previous)
	e.refreshProgress(r, true)
	return nil
}

func toFileError(err error) *Error {
	if disk.IsFull(err) {
		return &Error{Code: CodeDiskFull, Message: err.Error()}
	}
	return &Error{Code: CodeFileError, Message: err.Error()}
}

func isComplete(state *transfer.State) bool {
	return len(state.VerifiedParts) == piece.PartCount(state.Size) && piece.Set(state.VerifiedParts).IsFull()
}

func (e *Engine) addRun(r *run) {
	delete(e.stopped, r.file.Hash)
	e.runByHash[r.file.Hash] = r
	e.runs = append(e.runs, r)
}

// runByID searches the runs: only commands and disk results name a run by id.
func (e *Engine) runByID(id RunID) *run {
	if i := slices.IndexFunc(e.runs, func(r *run) bool { return r.id == id }); i >= 0 {
		return e.runs[i]
	}
	return nil
}

func (e *Engine) startTransfer(r *run, state *transfer.State, previous *transfer.Transfer) {
	mode := transfer.ModeDownload
	if r.mode == ModeSeed {
		mode = transfer.ModeSeed
	}
	var actions []transfer.Action
	r.transfer, actions = transfer.Build(transfer.Options{
		File:     r.file,
		Path:     r.path,
		State:    state,
		Mode:     mode,
		Random:   e.ports.Rand,
		Previous: previous,
	}, e.now())
	e.refreshShare(r)
	e.runTransferActions(r, actions)
}

// onFileHashed finishes checking a seed's file: a match makes it a
// complete Transfer, anything else ends the run.
func (e *Engine) onFileHashed(r *run, partHashes []wire.Hash, fileHash wire.Hash) {
	if fileHash != r.file.Hash {
		e.stopRun(r, &Error{Code: CodeFileError, Message: r.path + " does not match the link"})
		return
	}
	state := transfer.State{
		Size:          r.file.Size,
		File:          r.path,
		PartHashes:    partHashes,
		VerifiedParts: piece.BuildFullSet(piece.PartCount(r.file.Size)),
		Created:       e.now(),
	}
	if old, ok := e.state.Transfers[r.file.Hash]; ok {
		state.Uploaded = old.Uploaded
		state.Created = old.Created
	}
	e.startTransfer(r, &state, nil)
}

func (e *Engine) refreshShare(r *run) {
	state := r.transfer.ToState()
	r.share = peer.Share{Name: r.file.Name, Size: r.file.Size, Parts: state.VerifiedParts, PartHashes: state.PartHashes, Tree: r.tree}
}

func (e *Engine) shareByHash(file wire.Hash) (peer.Share, bool) {
	r := e.runByHash[file]
	if r == nil || r.transfer == nil || r.share.Parts.Count() == 0 {
		return peer.Share{}, false
	}
	return r.share, true
}

func (e *Engine) downloadByHash(file wire.Hash) *run {
	r := e.runByHash[file]
	if r == nil || r.transfer == nil || r.mode != ModeDownload {
		return nil
	}
	return r
}

// stopRun ends r exactly once and keeps its Durable State, and a download's
// sources for the next Run.
func (e *Engine) stopRun(r *run, err *Error) {
	h := r.file.Hash
	if r.transfer != nil {
		e.runTransferActions(r, r.transfer.Stop(e.now()))
		if r.mode == ModeDownload {
			e.stopped[h] = stoppedRun{transfer: r.transfer, asked: r.asked, at: e.now()}
		}
	}
	for _, c := range e.sortedConns() {
		e.removeFile(c, h, "run ended")
	}
	e.releaseA4AF(h)
	e.runQueueActions(e.queue.RemoveFile(h))
	if r.transfer != nil {
		e.refreshProgress(r, false)
		e.state.Transfers[h] = store.Transfer(r.transfer.ToState())
	}
	if closeErr := r.handle.Close(); closeErr != nil && err == nil {
		err = toFileError(closeErr)
	}
	delete(e.runByHash, h)
	e.runs = slices.DeleteFunc(e.runs, func(other *run) bool { return other == r })
	e.events.SendEnded(r.id, err)
	e.requestSave()
}

// refreshRuns ends every run whose Transfer reached its outcome.
func (e *Engine) refreshRuns() {
	for _, r := range slices.Clone(e.runs) {
		if r.transfer == nil {
			continue
		}
		switch outcome := r.transfer.Outcome(); outcome.Status {
		case transfer.StatusFailed:
			e.stopRun(r, &Error{Code: CodeFileError, Message: outcome.Message})
		case transfer.StatusDiskFull:
			e.stopRun(r, &Error{Code: CodeDiskFull, Message: outcome.Message})
		case transfer.StatusComplete:
			if r.mode == ModeDownload && !r.isSyncing {
				r.isSyncing = true
				e.disk.send(diskJob{kind: jobSync, run: r.id, file: r.handle})
			}
		}
	}
}

func (e *Engine) refreshProgress(r *run, isFirst bool) {
	progress := Progress{Hash: r.file.Hash, Size: r.file.Size}
	if r.transfer != nil {
		p := r.transfer.Progress(e.now())
		progress = Progress{
			Hash:            r.file.Hash,
			Size:            p.Size,
			Received:        p.Received,
			NetworkReceived: p.NetworkReceived,
			DownloadRate:    p.DownloadRate,
			UploadRate:      p.UploadRate,
			Uploaded:        p.Uploaded,
			Peers:           p.Peers,
			ActivePeers:     p.ActivePeers,
			HeldSources:     p.HeldSources,
			HeldUntil:       p.HeldUntil,
		}
		for _, s := range p.Sources {
			progress.Sources = append(progress.Sources, Source{
				Address:      s.Address,
				Software:     s.Software,
				Status:       s.Status,
				Rank:         s.Rank,
				DownloadRate: s.DownloadRate,
				Channel:      string(s.Channel),
			})
		}
	}
	if !isFirst && reflect.DeepEqual(progress, r.progress) {
		return
	}
	r.progress = progress
	e.events.SetProgress(r.id, progress)
}

func (e *Engine) runTransfers(now time.Time) {
	budget := e.connectBudget(now)
	n := len(e.runs)
	order := make([]*run, 0, n)
	for i := range n {
		order = append(order, e.runs[(e.budgetCursor+i)%n])
	}
	e.budgetCursor++
	server, _ := e.server.Login()
	isOffline := e.isOffline()
	for _, r := range order {
		if r.transfer == nil || e.runByHash[r.file.Hash] != r {
			continue
		}
		actions := r.transfer.OnTick(transfer.Tick{
			Now:           now,
			ConnectBudget: budget,
			Server:        server,
			IsFirewalled:  e.isFirewalled(),
			// Explicit link sources can be reached while discovery is offline.
			IsOffline:  isOffline && len(r.file.Sources) == 0,
			PublicIP:   e.publicIP,
			Port:       uint16(e.tcpPort),
			LocalAddrs: e.config.LocalAddrs,
		})
		for _, action := range actions {
			if _, isConnect := action.(transfer.Connect); isConnect {
				budget--
			}
		}
		e.runTransferActions(r, actions)
	}
}

// isOffline: no server is logged in and Kad has no verified node, aMule's
// !theApp->IsConnected(). With no server listed and Kad off nothing tells
// whether we are online and only link sources are known, which are then
// asked as usual.
func (e *Engine) isOffline() bool {
	server, _ := e.server.Login()
	return (e.kad != nil || len(e.server.Entries()) > 0) && !server.IsValid() && e.kadStatus.Nodes == 0
}

// connectBudget follows maxConnections and maxNewConnections.
func (e *Engine) connectBudget(now time.Time) int {
	e.recentConnects = slices.DeleteFunc(e.recentConnects, func(at time.Time) bool {
		return now.Sub(at) >= newConnectionWindow
	})
	return max(0, min(maxConnections-len(e.conns), maxNewConnections-len(e.recentConnects)))
}

func (e *Engine) runTransferActions(r *run, actions []transfer.Action) {
	now := e.now()
	for _, action := range actions {
		if e.runByHash[r.file.Hash] != r {
			return
		}
		switch a := action.(type) {
		case transfer.Connect:
			if e.deferConnect(r, a) {
				continue
			}
			c := e.connByEndpoint(a.Endpoint)
			if c == nil {
				c = e.openPeerConn(a.Endpoint, a.UserHash, a.CanObfuscate)
			}
			e.addFile(c, r)
		case transfer.ReaskUDP:
			if e.deferUDPReask(r, a.Endpoint) {
				continue
			}
			e.sendPeerDatagram(a.Endpoint, client.ReaskFilePing{
				Hash:               r.file.Hash,
				HasParts:           true,
				Parts:              peer.ToStatus(r.share),
				HasCompleteSources: true,
			}, a.UserHash, a.CanObfuscate)
		case transfer.RequestServerCallback:
			e.requestServerCallback(a.ClientID)
		case transfer.RequestKadCallback:
			switch {
			case a.IsDirect:
				e.requestDirectCallback(a.Buddy, a.UserHash, a.CanObfuscate)
			case e.kad != nil:
				e.kad.Post(toKadCallback(a, r.file.Hash))
			}
		case transfer.RequestSources:
			if c := e.conns[a.Peer]; c != nil && c.session != nil {
				e.runSession(c, c.session.RequestSources(r.file.Hash, now))
			}
		case transfer.RequestHashSet:
			if c := e.conns[a.Peer]; c != nil && c.session != nil {
				e.runSession(c, c.session.RequestHashSet(r.file.Hash))
			}
		case transfer.Write:
			e.disk.send(diskJob{kind: jobWrite, run: r.id, file: r.handle, block: a.Block, data: a.Data})
		case transfer.HashPart:
			e.disk.send(diskJob{kind: jobHashPart, run: r.id, file: r.handle, part: a.Part, block: piece.PartRange(r.file.Size, a.Part)})
		case transfer.HashBlocks:
			e.disk.send(diskJob{kind: jobHashBlocks, run: r.id, file: r.handle, part: a.Part, block: piece.PartRange(r.file.Size, a.Part)})
		case transfer.RequestRecovery:
			if c := e.conns[a.Peer]; c != nil && c.session != nil {
				e.runSession(c, c.session.RequestRecovery(r.file.Hash, a.Part, a.Root))
			}
		case transfer.Close:
			if c := e.conns[a.Peer]; c != nil {
				e.removeFile(c, r.file.Hash, a.Reason)
				if a.IsBanned {
					e.closeConn(c, a.Reason)
				}
			}
		case transfer.TraceEvent:
			e.sendTrace(a)
		}
	}
}

// refreshAsked forgets file requests older than the reask time, which no
// longer hold back a request on an incoming connection.
func (e *Engine) refreshAsked() {
	now := e.now()
	for _, r := range e.runs {
		maps.DeleteFunc(r.asked, func(_ wire.Hash, asked time.Time) bool {
			return now.Sub(asked) >= fileReaskTime
		})
	}
}

func (e *Engine) refreshStopped() {
	now := e.now()
	maps.DeleteFunc(e.stopped, func(_ wire.Hash, s stoppedRun) bool {
		return now.Sub(s.at) >= stoppedTime
	})
}

// matchKnownSource lists the downloads that know the peer as a source, in
// run order.
func (e *Engine) matchKnownSource(user wire.Hash, caps peer.Capabilities) []wire.Hash {
	found := transfer.Source{UserHash: user, ClientID: caps.ClientID, Server: caps.Server}
	var files []wire.Hash
	for _, r := range e.runs {
		if e.downloadByHash(r.file.Hash) != nil && r.transfer.MatchSource(found) {
			files = append(files, r.file.Hash)
		}
	}
	return files
}
