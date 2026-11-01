package engine

import (
	"maps"
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/transfer"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// A client grants upload slots per client, not per file. It counts every
// OP_STARTUPLOADREQ and OP_REASKFILEPING within MIN_REQUESTTIME as aggressive
// whatever file it names (aMule UploadClient.cpp:647-677,
// ClientTCPSocket.cpp:539, ClientUDPSocket.cpp:194), and OP_SETREQFILEID
// changes which file it thinks we wait for (ClientTCPSocket.cpp:425-460). So,
// like aMule with its request file and A4AF ("asking for another file") list
// (DownloadClient.cpp:496-517, 1431-1540), the engine asks each client for
// one download at a time; every other download that knows the client leaves
// it alone until the client is swapped over to it.

const (
	// minRequestTime is MIN_REQUESTTIME (Constants.h:67).
	minRequestTime = 590 * time.Second
	// swapSuspendTime is PURGESOURCESWAPSTOP (Constants.h:69): a client is
	// not swapped back to a download it left for having no needed parts.
	swapSuspendTime = 15 * time.Minute
	// a4afTime is how long a download holds a client after asking it: twice
	// FILEREASKTIME, the reask of a source with no needed parts. A holder
	// that stops asking frees the client.
	a4afTime = 2 * fileReaskTime
)

// a4afClient is what the engine remembers of one client across
// connections: the download it last asked a slot for (aMule's m_reqfile),
// and the downloads it was swapped away from.
type a4afClient struct {
	file      wire.Hash
	lastAsked time.Time
	endpoint  netip.AddrPort
	suspended map[wire.Hash]time.Time
}

func (e *Engine) a4afClientByUser(user wire.Hash) *a4afClient {
	client := e.a4afClients[user]
	if client == nil {
		client = &a4afClient{suspended: map[wire.Hash]time.Time{}}
		e.a4afClients[user] = client
	}
	return client
}

// onSlotAsked records that c sent OP_STARTUPLOADREQ for file.
func (e *Engine) onSlotAsked(c *conn, file wire.Hash) {
	client := e.a4afClientByUser(c.session.Capabilities().UserHash)
	client.file = file
	client.lastAsked = e.now()
	client.endpoint = c.endpoint()
	if r := e.downloadByHash(file); r != nil {
		r.transfer.OnSlotAsked(c.id, e.now())
	}
}

// isA4AF tells whether another running download holds the client.
func (e *Engine) isA4AF(user, file wire.Hash) bool {
	client := e.a4afClients[user]
	return client != nil && client.file != file && e.downloadByHash(client.file) != nil &&
		e.now().Before(client.lastAsked.Add(a4afTime))
}

// deferConnect keeps r from connecting to a client another download holds,
// recognised by user hash or, while the source has none, by endpoint
// (aMule CheckAndAddSource, DownloadQueue.cpp:623-717).
func (e *Engine) deferConnect(r *run, a transfer.Connect) bool {
	user := a.UserHash
	if user == (wire.Hash{}) {
		for known, client := range e.a4afClients {
			if client.endpoint == a.Endpoint {
				user = known
			}
		}
	}
	if !e.isA4AF(user, r.file.Hash) {
		return false
	}
	client := e.a4afClients[user]
	r.transfer.SetA4AF(transfer.Source{Endpoint: a.Endpoint, UserHash: user}, client.lastAsked.Add(a4afTime))
	return true
}

// deferUDPReask keeps r from UDP-reasking a client another download holds;
// a reask by the holder counts as asking it.
func (e *Engine) deferUDPReask(r *run, to netip.AddrPort) bool {
	for user, client := range e.a4afClients {
		if client.endpoint.Addr() != to.Addr() {
			continue
		}
		if client.file == r.file.Hash {
			client.lastAsked = e.now()
		}
		return e.isA4AF(user, r.file.Hash)
	}
	return false
}

// canAskSlot is peer.Config.CanAskSlot: a client is asked for another
// download than the one it was last asked for only after MIN_REQUESTTIME.
func (e *Engine) canAskSlot(user, file wire.Hash) bool {
	client := e.a4afClients[user]
	return client == nil || client.file == file || e.now().Sub(client.lastAsked) >= minRequestTime
}

// onNoNeededParts takes a download whose peer has no part we need off the
// connection and swaps the peer to another download, one on the connection
// or one that knows the peer, that it was not swapped away from within
// PURGESOURCESWAPSTOP (aMule PartFile.cpp:1559-1573,
// SwapToAnotherFile(false, false, false)). Without a download to swap to the
// peer stays a source of this one, as aMule keeps a DS_NONEEDEDPARTS client
// in m_SrcList: a part its blocks completed may still fail its hash and need
// the peer's AICH recovery data (PartFile.cpp:3838-3846).
func (e *Engine) onNoNeededParts(c *conn, file wire.Hash) {
	r := e.downloadByHash(file)
	if files := c.session.Files(); r == nil || len(files) == 0 || files[0] != file {
		return
	}
	if !r.transfer.OnNoNeededParts(c.id) {
		return
	}
	user := c.session.Capabilities().UserHash
	target := e.swapTarget(c, user, file, false)
	if target == nil {
		return
	}
	e.a4afClientByUser(user).suspended[file] = e.now().Add(swapSuspendTime)
	e.removeFile(c, file, "no needed parts")
	if !c.isClosed {
		e.addFile(c, target)
	}
}

// onFileRejected swaps a peer that does not have a download, which its
// session already forgot, to any other download that knows it (aMule
// ClientTCPSocket.cpp:480-500, SwapToAnotherFile(true, true, true)).
func (e *Engine) onFileRejected(c *conn, file wire.Hash) {
	if r := e.downloadByHash(file); r != nil {
		e.removeTransferPeer(c, r, "no file", e.now())
	}
	if len(c.session.Files()) > 0 || c.isClosed {
		return
	}
	if target := e.swapTarget(c, c.session.Capabilities().UserHash, file, true); target != nil {
		e.addFile(c, target)
	}
}

// releaseA4AF hands every client the download held to the next download
// that knows it, to be asked when the client's reask is due (aMule
// CPartFile::RemoveAllSources(true), PartFile.cpp:2350-2377).
func (e *Engine) releaseA4AF(file wire.Hash) {
	for user, client := range e.a4afClients {
		delete(client.suspended, file)
		if client.file != file {
			continue
		}
		target := e.swapTarget(nil, user, file, true)
		if target == nil {
			delete(e.a4afClients, user)
			continue
		}
		client.file = target.file.Hash
		target.transfer.SetA4AF(transfer.Source{Endpoint: client.endpoint, UserHash: user}, client.lastAsked.Add(fileReaskTime))
	}
}

// swapTarget picks the download a client goes to from file: one already on
// c, else the first running download that knows the client, in run order as
// aMule takes the highest priority. Downloads the client was swapped away
// from recently are skipped, or only put last when isAnyFile.
func (e *Engine) swapTarget(c *conn, user, file wire.Hash, isAnyFile bool) *run {
	var candidates []wire.Hash
	if c != nil {
		candidates = append(candidates, c.session.Files()...)
	}
	for _, r := range e.runs {
		if r.transfer != nil && r.transfer.MatchSource(transfer.Source{UserHash: user}) {
			candidates = append(candidates, r.file.Hash)
		}
	}
	now := e.now()
	var fallback *run
	for _, h := range candidates {
		r := e.downloadByHash(h)
		if h == file || r == nil {
			continue
		}
		client := e.a4afClients[user]
		if client == nil || !now.Before(client.suspended[h]) {
			return r
		}
		if isAnyFile && fallback == nil {
			fallback = r
		}
	}
	return fallback
}

// refreshA4AF forgets clients no download holds any more and that have no
// swap suspension left: they no longer change any decision.
func (e *Engine) refreshA4AF() {
	now := e.now()
	maps.DeleteFunc(e.a4afClients, func(_ wire.Hash, client *a4afClient) bool {
		maps.DeleteFunc(client.suspended, func(_ wire.Hash, until time.Time) bool { return !now.Before(until) })
		return len(client.suspended) == 0 && !now.Before(client.lastAsked.Add(a4afTime))
	})
}
