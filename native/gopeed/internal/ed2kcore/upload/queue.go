// Package upload decides which peers get an upload slot, following eMule's
// upload queue so that peers ranking us by our uploads see a good citizen.
package upload

import (
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/identity"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const (
	queueSize        = 5000                     // CPreferences::m_iQueueSize default 50*100
	hardQueueSize    = queueSize + queueSize/4  // CUploadQueue::AddClientToQueue: soft limit + max(soft/4, 200)
	queueFullMargin  = 50                       // OP_REASKFILEPING answers OP_QUEUEFULL when waiting+50 > queue size
	maxSameIP        = 3                        // AddClientToQueue: at most 3 waiting clients from one IP
	maxPurgeTime     = time.Hour                // MAX_PURGEQUEUETIME
	sessionMaxTrans  = piece.PartSize + 20*1024 // SESSIONMAXTRANS
	sessionMaxTime   = time.Hour                // SESSIONMAXTIME
	connectTimeout   = 40 * time.Second         // CONNECTION_TIMEOUT
	minSlots         = 2                        // MIN_UP_CLIENTS_ALLOWED
	unlimitedSlots   = 20                       // aMule's N_FLOOR without an upload limit
	maxSlots         = 100                      // MAX_UP_CLIENTS_ALLOWED
	maxSlotRate      = 50 * 1024                // UPLOAD_CLIENT_MAXDATARATE
	slotSpacing      = time.Second              // ForceNewClient: one new slot per second below 100 KB/s
	fastRate         = 102400                   // ForceNewClient: above this rate slots may open faster
	datarateWindow   = 30 * time.Second         // CUploadQueue::Process keeps 30 s of rate samples
	autoHighQueued   = 1                        // CKnownFile::UpdateAutoUpPriority: <=1 queued is PR_HIGH
	autoNormalQueued = 20                       // <=20 queued is PR_NORMAL, more is PR_LOW
	oldMuleVersion   = 0x19                     // CalculateScoreInternal halves eMule 0.19 and older
)

// Peer is a downloader as the queue knows it. User and IP together are its
// identity: a queued downloader usually disconnects and comes back over UDP or
// a new TCP connection.
type Peer struct {
	User    wire.Hash
	IP      netip.Addr
	UDPPort uint16
	IsLowID bool
	// MuleVersion is peer.Capabilities.MuleVersion.
	MuleVersion byte
}

// isOld is aMule's test for clients from before eMule 0.20
// (UploadClient.cpp:144): an old eMule protocol version, or no version at all
// from a client whose user hash marks it as eMule.
func (p Peer) isOld() bool {
	return p.MuleVersion <= oldMuleVersion && (p.MuleVersion > 0 || identity.IsEmuleHash(p.User))
}

type key struct {
	user wire.Hash
	ip   netip.Addr
}

func (p Peer) key() key { return key{p.User, p.IP} }

// Action is something the engine must do on the queue's behalf.
type Action interface{ isAction() }

// Grant tells the engine to send OP_ACCEPTUPLOADREQ on Conn.
type Grant struct{ Conn uint64 }

// Revoke tells the engine to stop serving Conn and send OP_OUTOFPARTREQS.
type Revoke struct{ Conn uint64 }

// SendRank tells the engine to send OP_QUEUERANKING with Rank on Conn.
type SendRank struct {
	Conn uint64
	Rank int
}

// Connect asks the engine to connect to a HighID waiter whose turn has come and
// report the connection through OnConnected.
type Connect struct{ Peer Peer }

func (Grant) isAction()    {}
func (Revoke) isAction()   {}
func (SendRank) isAction() {}
func (Connect) isAction()  {}

// Answer is the reply to a UDP reask; nil means stay silent, which makes the
// peer fall back to TCP.
type Answer interface{ isAnswer() }

// ReaskAck and FileNotFound carry the asking waiter's user hash, zero when
// the asker is not known, so that the engine can obfuscate the answer for
// it (ClientUDPSocket.cpp:185, 226).
type ReaskAck struct {
	Rank int
	User wire.Hash
}
type FileNotFound struct{ User wire.Hash }
type QueueFull struct{}

func (ReaskAck) isAnswer()     {}
func (FileNotFound) isAnswer() {}
func (QueueFull) isAnswer()    {}

type waiter struct {
	peer Peer
	file wire.Hash
	// conn is the peer's connection, 0 while it has none; the engine
	// numbers connections from 1.
	conn          uint64
	waitStart     time.Time
	lastAsk       time.Time
	isNextConnect bool
}

type slot struct {
	peer  Peer
	file  wire.Hash
	conn  uint64
	start time.Time
	sent  int64
}

type sample struct {
	at    time.Time
	bytes int64
}

// Queue is the waiting queue and the upload slots of one Engine Process.
type Queue struct {
	ratio         func(user wire.Hash, ip netip.Addr) float64
	trust         func(user wire.Hash, ip netip.Addr) identity.Trust
	isShared      func(file wire.Hash) bool
	waiters       map[key]*waiter
	slots         []*slot
	rate          int64
	lastSlotStart time.Time
	sentSinceTick int64
	samples       []sample
	datarate      int64
}

// BuildQueue takes the credit ratio and trust (identity.Ledger.Ratio and
// TrustByUser) and whether a file is shared: requests and reasks for other
// files are not queued.
func BuildQueue(
	ratio func(user wire.Hash, ip netip.Addr) float64,
	trust func(user wire.Hash, ip netip.Addr) identity.Trust,
	isShared func(file wire.Hash) bool,
) *Queue {
	return &Queue{
		ratio:    ratio,
		trust:    trust,
		isShared: isShared,
		waiters:  map[key]*waiter{},
	}
}

// SetRate sets the upload Rate Limit in bytes per second; 0 is unlimited.
func (q *Queue) SetRate(bytesPerSecond int64) {
	q.rate = bytesPerSecond
}

// RemoveFile drops the waiters and revokes the slots of a file that is no
// longer shared.
func (q *Queue) RemoveFile(file wire.Hash) []Action {
	for k, w := range q.waiters {
		if w.file == file {
			delete(q.waiters, k)
		}
	}
	var actions []Action
	kept := q.slots[:0]
	for _, s := range q.slots {
		if s.file != file {
			kept = append(kept, s)
			continue
		}
		if s.conn != 0 {
			actions = append(actions, Revoke{s.conn})
		}
	}
	q.slots = kept
	return actions
}

// OnConnected reports that a TCP connection to peer finished its hello.
func (q *Queue) OnConnected(conn uint64, peer Peer, now time.Time) []Action {
	if s := q.slotByKey(peer.key()); s != nil {
		s.peer, s.conn = peer, conn
		return []Action{Grant{conn}}
	}
	w := q.waiters[peer.key()]
	if w == nil {
		return nil
	}
	w.peer, w.conn = peer, conn
	if w.isNextConnect && q.canAddNextConnect() {
		return []Action{q.startSlot(w, now)}
	}
	return nil
}

// OnRequest handles OP_STARTUPLOADREQ for file from peer on conn.
func (q *Queue) OnRequest(conn uint64, peer Peer, file wire.Hash, now time.Time) []Action {
	if !q.isShared(file) {
		return nil
	}
	k := peer.key()
	if s := q.slotByKey(k); s != nil {
		s.peer, s.file, s.conn = peer, file, conn
		return []Action{Grant{conn}}
	}
	if w := q.waiters[k]; w != nil {
		w.peer, w.file, w.conn, w.lastAsk = peer, file, conn, now
		if w.isNextConnect && q.canAddNextConnect() {
			return []Action{q.startSlot(w, now)}
		}
		return []Action{SendRank{conn, q.rank(w, now)}}
	}
	if !q.removeDuplicates(peer) || !q.canQueue(peer, file) {
		return nil
	}
	w := &waiter{peer: peer, file: file, conn: conn, waitStart: now, lastAsk: now}
	if len(q.waiters) == 0 && q.canAddSlot(now) {
		return []Action{q.startSlot(w, now)}
	}
	q.waiters[k] = w
	return []Action{SendRank{conn, q.rank(w, now)}}
}

// OnReask answers a UDP OP_REASKFILEPING for file from ip:udpPort.
func (q *Queue) OnReask(ip netip.Addr, udpPort uint16, file wire.Hash, now time.Time) Answer {
	w, isAmbiguous := q.waiterByUDP(ip, udpPort)
	if !q.isShared(file) {
		var user wire.Hash
		if w != nil {
			user = w.peer.User
		}
		return FileNotFound{user}
	}
	if w == nil {
		if !isAmbiguous && len(q.waiters)+queueFullMargin > queueSize {
			return QueueFull{}
		}
		return nil
	}
	if w.file != file {
		return nil
	}
	w.lastAsk = now
	return ReaskAck{q.rank(w, now), w.peer.User}
}

// OnConnectionGone forgets conn. A peer losing its slot this way is not queued
// again; it asks anew like any other peer.
func (q *Queue) OnConnectionGone(conn uint64) {
	for _, w := range q.waiters {
		if w.conn == conn {
			w.conn = 0
		}
	}
	q.slots = slices.DeleteFunc(q.slots, func(s *slot) bool { return s.conn == conn })
}

// HasPeer reports whether the peer is waiting or holds a slot, so the queue
// may still ask the engine to connect to it.
func (q *Queue) HasPeer(user wire.Hash, ip netip.Addr) bool {
	k := key{user, ip}
	return q.waiters[k] != nil || q.slotByKey(k) != nil
}

// OnSent counts payload bytes sent on conn.
func (q *Queue) OnSent(conn uint64, bytes int64) {
	q.sentSinceTick += bytes
	if s := q.slotByConn(conn); s != nil {
		s.sent += bytes
	}
}

// OnTick purges, rotates and opens slots. Call it about every 100 ms, as eMule
// runs CUploadQueue::Process.
func (q *Queue) OnTick(now time.Time) []Action {
	q.updateDatarate(now)
	for k, w := range q.waiters {
		if now.Sub(w.lastAsk) > maxPurgeTime {
			delete(q.waiters, k)
		}
	}
	var actions []Action
	var rotated []*slot
	// aMule rotates a slot only while no new one may open, and one per round
	// (UploadQueue.cpp:246-258, 586-624): with room to spare the waiter gets a
	// new slot instead of interrupting a download.
	canRotate := len(q.waiters) > 0 && now.Sub(q.lastSlotStart) >= slotSpacing && !q.canAddSlot(now)
	kept := q.slots[:0]
	for _, s := range q.slots {
		switch {
		case s.conn == 0 && now.Sub(s.start) > connectTimeout:
		case canRotate && s.conn != 0 && (s.sent > sessionMaxTrans || now.Sub(s.start) > sessionMaxTime):
			canRotate = false
			actions = append(actions, Revoke{s.conn})
			rotated = append(rotated, s)
		default:
			kept = append(kept, s)
		}
	}
	q.slots = kept
	for _, s := range rotated {
		w := &waiter{peer: s.peer, file: s.file, conn: s.conn, waitStart: now, lastAsk: now}
		q.waiters[s.peer.key()] = w
		actions = append(actions, SendRank{s.conn, q.rank(w, now)})
	}
	if len(q.waiters) > 0 && q.canAddSlot(now) {
		if w := q.bestWaiter(now); w != nil {
			actions = append(actions, q.startSlot(w, now))
		}
	}
	return actions
}

func (q *Queue) startSlot(w *waiter, now time.Time) Action {
	delete(q.waiters, w.peer.key())
	s := &slot{peer: w.peer, file: w.file, conn: w.conn, start: now}
	q.slots = append(q.slots, s)
	q.lastSlotStart = now
	if s.conn == 0 {
		return Connect{s.peer}
	}
	return Grant{s.conn}
}

// removeDuplicates applies AddClientToQueue's rule for one user hash waiting
// from two addresses (aMule UploadQueue.cpp:446-468, eMule alike): a waiter
// identified by Secure User Identification keeps its place and the newcomer is
// ignored; otherwise the waiters are removed and the newcomer queues only if it
// is identified. It reports whether the newcomer may queue.
func (q *Queue) removeDuplicates(peer Peer) bool {
	var duplicates []key
	for k, w := range q.waiters {
		if w.peer.User != peer.User {
			continue
		}
		if q.trust(w.peer.User, w.peer.IP) == identity.TrustIdentified {
			return false
		}
		duplicates = append(duplicates, k)
	}
	for _, k := range duplicates {
		delete(q.waiters, k)
	}
	return len(duplicates) == 0 || q.trust(peer.User, peer.IP) == identity.TrustIdentified
}

// canQueue applies eMule's admission rules for a newcomer: three peers per IP,
// and past the soft limit only peers above the average priority × credit.
func (q *Queue) canQueue(peer Peer, file wire.Hash) bool {
	sameIP := 0
	for _, w := range q.waiters {
		if w.peer.IP == peer.IP {
			sameIP++
		}
	}
	if sameIP >= maxSameIP {
		return false
	}
	n := len(q.waiters)
	if n >= hardQueueSize {
		return false
	}
	if n < queueSize {
		return true
	}
	counts := q.fileCounts()
	sum := 0.0
	for _, w := range q.waiters {
		sum += q.ratio(w.peer.User, w.peer.IP) * filePriority(counts[w.file])
	}
	return q.ratio(peer.User, peer.IP)*filePriority(counts[file]+1) >= sum/float64(n)
}

// bestWaiter is eMule's FindBestClientInQueue: a disconnected LowID waiter
// cannot be called, so when it would have won it is flagged to get the slot as
// soon as it connects.
func (q *Queue) bestWaiter(now time.Time) *waiter {
	counts := q.fileCounts()
	var best, bestLow *waiter
	bestScore, bestLowScore := 0.0, 0.0
	for _, w := range q.waiters {
		score := q.score(w, counts, now)
		if score <= bestScore {
			continue
		}
		if !w.peer.IsLowID || w.conn != 0 {
			best, bestScore = w, score
		} else if !w.isNextConnect && score > bestLowScore {
			bestLow, bestLowScore = w, score
		}
	}
	if bestLow != nil && bestLowScore > bestScore {
		bestLow.isNextConnect = true
	}
	return best
}

// score is eMule's CUpDownClient::GetScore: seconds waited × credit ratio ×
// file priority / 10, halved for old clients. Impostors of an identified
// user score 0 and are never chosen (aMule UploadClient.cpp:91).
func (q *Queue) score(w *waiter, counts map[wire.Hash]int, now time.Time) float64 {
	if q.trust(w.peer.User, w.peer.IP) == identity.TrustImpostor {
		return 0
	}
	score := now.Sub(w.waitStart).Seconds() * q.ratio(w.peer.User, w.peer.IP) * filePriority(counts[w.file]) / 10
	if w.peer.isOld() {
		score /= 2
	}
	return score
}

// rank is eMule's GetWaitingPosition: one plus the waiters scoring higher.
func (q *Queue) rank(w *waiter, now time.Time) int {
	counts := q.fileCounts()
	own := q.score(w, counts, now)
	rank := 1
	for _, other := range q.waiters {
		if q.score(other, counts, now) > own {
			rank++
		}
	}
	return rank
}

// filePriority is eMule's default automatic upload priority (UAPPref on),
// which favours files few peers are asking for: PR_HIGH 9, PR_NORMAL 7,
// PR_LOW 6 as GetFilePrioAsNumber weighs them.
func filePriority(queued int) float64 {
	switch {
	case queued <= autoHighQueued:
		return 9
	case queued <= autoNormalQueued:
		return 7
	default:
		return 6
	}
}

// fileCounts is eMule's CKnownFile::GetQueuedCount for every file: peers
// waiting for or being served the file.
func (q *Queue) fileCounts() map[wire.Hash]int {
	counts := map[wire.Hash]int{}
	for _, w := range q.waiters {
		counts[w.file]++
	}
	for _, s := range q.slots {
		counts[s.file]++
	}
	return counts
}

// canAddNextConnect is eMule's AcceptNewClient(addOnNextConnect): a LowID peer
// skipped while unreachable may take one slot beyond the usual count.
func (q *Queue) canAddNextConnect() bool {
	n := len(q.slots)
	if n > 0 {
		n--
	}
	return q.canAcceptSlot(n)
}

// canAddSlot is eMule's ForceNewClient; callers check the queue first, as
// a newcomer to an empty queue may take a slot directly.
func (q *Queue) canAddSlot(now time.Time) bool {
	if now.Sub(q.lastSlotStart) < slotSpacing && q.datarate < fastRate {
		return false
	}
	n := len(q.slots)
	if n < q.slotFloor() {
		return true
	}
	if !q.canAcceptSlot(n) {
		return false
	}
	perSlot := q.slotTarget()
	if q.rate == 0 || q.rate > 20*1024 {
		perSlot += q.datarate / 43
	}
	perSlot = min(perSlot, maxSlotRate)
	if q.rate == 0 {
		return int64(n) < q.datarate/perSlot
	}
	return n < limitedSlots(q.rate, perSlot)
}

// limitedSlots is ForceNewClient's slot count under a Rate Limit; slow links
// get fixed small counts so each slot keeps a usable speed.
func limitedSlots(rate, perSlot int64) int {
	switch kb := rate / 1024; {
	case kb > 12:
		return int(rate / perSlot)
	case kb > 7:
		return minSlots + 2
	case kb > 3:
		return minSlots + 1
	default:
		return minSlots
	}
}

// canAcceptSlot is eMule's AcceptNewClient: beyond four slots each must still
// be getting at least three quarters of its target rate.
func (q *Queue) canAcceptSlot(n int) bool {
	if n >= maxSlots {
		return false
	}
	if n < max(4, q.slotFloor()) {
		return true
	}
	target := q.slotTarget()
	if int64(n) >= q.datarate/(target*3/4) {
		return false
	}
	return q.rate == 0 || int64(n) < q.rate/target
}

// slotFloor is how many slots open on spacing alone. Without a Rate Limit
// aMule keeps 20 (UploadQueue.cpp:295-322): eMule's two let the rate that
// would justify more slots never come, as two streams rarely fill an
// upstream.
func (q *Queue) slotFloor() int {
	if q.rate == 0 {
		return unlimitedSlots
	}
	return minSlots
}

// slotTarget is eMule's GetTargetClientDataRate: 3 KB/s up to three slots,
// rising by 1.25 KB/s per slot to 50 KB/s at forty. eMule writes 3*1204, a typo
// for 3 KB/s.
func (q *Queue) slotTarget() int64 {
	n := int64(len(q.slots))
	switch {
	case n <= 3:
		return 3 * 1024
	case n >= 40:
		return maxSlotRate
	default:
		return min(maxSlotRate, n*1280)
	}
}

// updateDatarate averages the bytes sent over the last 30 s the way
// CUploadQueue::UpdateDatarates does: the oldest sample only marks the start.
func (q *Queue) updateDatarate(now time.Time) {
	q.samples = append(q.samples, sample{now, q.sentSinceTick})
	q.sentSinceTick = 0
	for len(q.samples) > 3 && now.Sub(q.samples[0].at) > datarateWindow {
		q.samples = q.samples[1:]
	}
	span := now.Sub(q.samples[0].at)
	if span <= 0 {
		q.datarate = 0
		return
	}
	var sum int64
	for _, s := range q.samples[1:] {
		sum += s.bytes
	}
	q.datarate = sum * int64(time.Second) / int64(span)
}

func (q *Queue) slotByKey(k key) *slot {
	for _, s := range q.slots {
		if s.peer.key() == k {
			return s
		}
	}
	return nil
}

func (q *Queue) slotByConn(conn uint64) *slot {
	for _, s := range q.slots {
		if s.conn == conn {
			return s
		}
	}
	return nil
}

// waiterByUDP is eMule's GetWaitingClientByIP_UDP: an exact IP and UDP port
// match, else the only waiter at that IP. Several waiters at the IP without a
// port match are ambiguous.
func (q *Queue) waiterByUDP(ip netip.Addr, udpPort uint16) (*waiter, bool) {
	var match *waiter
	matches := 0
	for _, w := range q.waiters {
		if w.peer.IP != ip {
			continue
		}
		if w.peer.UDPPort == udpPort {
			return w, false
		}
		match = w
		matches++
	}
	if matches == 1 {
		return match, false
	}
	return nil, matches > 1
}
