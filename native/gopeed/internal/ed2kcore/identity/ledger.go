// Derived from goed2k client_credits.go.

package identity

import (
	"bytes"
	"math"
	"net/netip"
	"sort"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// Credit is one user's persisted record. PublicKey is set once the user
// passes Secure User Identification and never changes afterwards.
type Credit struct {
	User       wire.Hash
	Uploaded   uint64
	Downloaded uint64
	PublicKey  []byte
	LastSeen   time.Time
}

// creditExpiry is how long a user may stay away before its credits are
// forgotten: aMule drops them at load after 150 days (ClientCreditsList.cpp:120).
const creditExpiry = 150 * 24 * time.Hour

// idleTime is how long a user without traffic is remembered after its last
// hello: KEEPTRACK_TIME (Constants.h:70), aMule's time to keep track of a
// client. Without it every user hash that ever greeted us stays in memory.
const idleTime = 2 * time.Hour

type account struct {
	credit Credit
	// verifiedIP is the address the user last proved its key from; invalid
	// until it does.
	verifiedIP netip.Addr
}

// Ledger keeps per-user credits and, for this process only, the address
// each user proved its key from. It follows eMule: a user with no known key
// is credited without identification; once a key is known, nothing is
// credited until the user is identified from the address it is talking
// from.
type Ledger struct {
	accounts map[wire.Hash]*account
}

// BuildLedger drops credits last seen more than 150 days before now. A
// credit imported without a last-seen time starts its 150 days now.
func BuildLedger(credits []Credit, now time.Time) *Ledger {
	ledger := &Ledger{accounts: make(map[wire.Hash]*account, len(credits))}
	for _, credit := range credits {
		if credit.LastSeen.IsZero() {
			credit.LastSeen = now
		}
		if now.Sub(credit.LastSeen) > creditExpiry {
			continue
		}
		ledger.accounts[credit.User] = &account{credit: credit}
	}
	return ledger
}

func (l *Ledger) accountByUser(user wire.Hash) *account {
	if a, ok := l.accounts[user]; ok {
		return a
	}
	a := &account{credit: Credit{User: user}}
	l.accounts[user] = a
	return a
}

// isTrusted reports whether credits may be counted and used for this user at ip.
func (a *account) isTrusted(ip netip.Addr) bool {
	return len(a.credit.PublicKey) == 0 || a.verifiedIP.IsValid() && a.verifiedIP == ip
}

// OnHello records that user greeted us, as aMule's GetCredit does on every
// Hello (BaseClient.cpp:680, ClientCreditsList.cpp:236).
func (l *Ledger) OnHello(user wire.Hash, now time.Time) {
	l.accountByUser(user).credit.LastSeen = now
}

// Trust is how far a user at an address has proven its user hash.
type Trust byte

const (
	TrustUnproven Trust = iota
	TrustIdentified
	// TrustImpostor: the user hash was proven from another address, so this
	// address is not that user (aMule's IS_IDBADGUY, ClientCredits.cpp:219).
	TrustImpostor
)

func (l *Ledger) TrustByUser(user wire.Hash, ip netip.Addr) Trust {
	a, ok := l.accounts[user]
	switch {
	case !ok || !a.verifiedIP.IsValid():
		return TrustUnproven
	case a.verifiedIP == ip:
		return TrustIdentified
	default:
		return TrustImpostor
	}
}

// OnIdentified records that user at ip signed with key. A user keeps the
// first key it was identified with, so a signature with another key proves
// nothing. Credits gathered before the first identification are unproven,
// so they are reset to one byte each, as eMule does.
func (l *Ledger) OnIdentified(user wire.Hash, ip netip.Addr, key []byte) {
	a := l.accountByUser(user)
	switch {
	case len(a.credit.PublicKey) == 0:
		a.credit.PublicKey = bytes.Clone(key)
		if a.credit.Downloaded > 0 {
			a.credit.Downloaded = 1
			a.credit.Uploaded = 1
		}
	case !bytes.Equal(a.credit.PublicKey, key):
		return
	}
	a.verifiedIP = ip
}

func (l *Ledger) OnTransferred(user wire.Hash, ip netip.Addr, uploadedToThem, downloadedFromThem int64) {
	a := l.accountByUser(user)
	if !a.isTrusted(ip) {
		return
	}
	a.credit.Uploaded += uint64(uploadedToThem)
	a.credit.Downloaded += uint64(downloadedFromThem)
}

// Ratio is the upload queue score multiplier for user at ip, from 1 to 10.
func (l *Ledger) Ratio(user wire.Hash, ip netip.Addr) float64 {
	a, ok := l.accounts[user]
	if !ok || !a.isTrusted(ip) || a.credit.Downloaded < 1000000 {
		return 1
	}
	ratio := 10.0
	if a.credit.Uploaded > 0 {
		ratio = float64(a.credit.Downloaded) * 2 / float64(a.credit.Uploaded)
	}
	ratio = math.Min(ratio, math.Sqrt(float64(a.credit.Downloaded)/1048576+2))
	return math.Max(1, math.Min(10, ratio))
}

// RemoveIdle forgets users without traffic whose last hello is idleTime
// old. They start over if they come back.
func (l *Ledger) RemoveIdle(now time.Time) {
	for user, a := range l.accounts {
		if !a.hasTraffic() && now.Sub(a.credit.LastSeen) >= idleTime {
			delete(l.accounts, user)
		}
	}
}

func (a *account) hasTraffic() bool {
	return a.credit.Uploaded > 0 || a.credit.Downloaded > 0
}

// ToCredits lists every user with traffic, sorted by user. Like aMule
// (ClientCreditsList.cpp:194) a key alone is not saved, so identities that
// never transferred anything do not pile up on disk.
func (l *Ledger) ToCredits() []Credit {
	credits := make([]Credit, 0, len(l.accounts))
	for _, a := range l.accounts {
		if !a.hasTraffic() {
			continue
		}
		credit := a.credit
		credit.PublicKey = bytes.Clone(credit.PublicKey)
		credits = append(credits, credit)
	}
	sort.Slice(credits, func(i, j int) bool {
		return bytes.Compare(credits[i].User[:], credits[j].User[:]) < 0
	})
	return credits
}
