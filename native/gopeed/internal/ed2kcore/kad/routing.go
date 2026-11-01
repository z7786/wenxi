// Derived from goed2k kad_routing.go.

package kad

import (
	"bytes"
	"math/rand/v2"
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

const (
	bucketSize = 10 // K: contacts per leaf
	// A contact that misses this many checks in a row leaves the table.
	maxFailures = 2
	maxLeaves   = 8
	// One /24 holds at most this many contacts in the table and in one
	// leaf, LAN addresses aside (RoutingBin.cpp:51, 88); each IP holds one.
	maxTableBySubnet = 10
	maxLeafBySubnet  = 2
)

type contact struct {
	Node
	// isVerified is set once the contact answered a request of ours.
	isVerified bool
	isHelloed  bool
	// udpKey is the sender verify key the contact last sent, which our
	// obfuscated packets to it carry back.
	udpKey   uint32
	failures int
	lastSeen time.Time
	leaf     int
}

type bucket struct {
	contacts     []*contact
	replacements []*contact
	nextChecks   [maxLeaves]time.Time
	nextLookups  [maxLeaves]time.Time
}

// table is a Kademlia routing table: bucket i holds contacts whose ID first
// differs from ours at bit i. Lookups only use the contacts, not the
// replacements, which wait for a contact of their leaf to fail.
//
// Like aMule's CRoutingBin, it keeps one contact per IP and few per /24, so
// that one machine or one subnet cannot fill a leaf and take over the
// lookups near it.
//
// eMule's routing zones split while their level is below KBASE (4) or their
// index below KK (5) (CRoutingZone::CanSplit). Bucket i is the zone at level
// i+1 with index 1, so it ends up as leaves of K contacts keyed by the
// distance bits after its leading 1: bucket 0 as eight (three bits each),
// every other bucket as five (000, 001, 01, 10, 11).
type table struct {
	self    wire.Hash
	buckets [128]bucket
	byID    map[wire.Hash]*contact
	// byIP holds the one contact an IP may have; a second ID at the same
	// IP replaces it only once verified.
	byIP map[netip.Addr]*contact
}

// buildTable makes an empty table whose leaves are first looked up
// bucketRefreshGap after now, as CRoutingZone::StartTimer schedules them.
func buildTable(self wire.Hash, now time.Time) *table {
	t := &table{self: self, byID: map[wire.Hash]*contact{}, byIP: map[netip.Addr]*contact{}}
	for i := range t.buckets {
		for leaf := range t.buckets[i].nextLookups {
			t.buckets[i].nextLookups[leaf] = now.Add(bucketRefreshGap)
		}
	}
	return t
}

// add inserts or updates a contact. A verified contact is one that just
// answered us; others are hearsay and never move a verified contact to a new
// address, nor take an IP or /24 slot from another contact.
func (t *table) add(n Node, isVerified bool, now time.Time) *contact {
	if n.ID == t.self || !matchGoodNode(n) {
		return nil
	}
	ip := n.Addr.Addr()
	c := t.byID[n.ID]
	if c == nil {
		if other := t.byIP[ip]; other != nil {
			if !isVerified {
				return nil
			}
			t.remove(other)
		}
		if !t.hasSubnetRoom(n.ID, ip) {
			return nil
		}
		c = &contact{Node: n}
		t.byID[n.ID] = c
		t.byIP[ip] = c
		t.addToBucket(c, isVerified)
	} else if c.Addr != n.Addr {
		if c.isVerified && !isVerified {
			return c
		}
		if other := t.byIP[ip]; other != nil && other != c {
			if !isVerified {
				return c
			}
			t.remove(other)
		}
		if c.Addr.Addr() != ip && !t.hasSubnetRoom(n.ID, ip) {
			return c
		}
		delete(t.byIP, c.Addr.Addr())
		c.Addr = n.Addr
		t.byIP[ip] = c
	}
	if n.TCPPort != 0 {
		c.TCPPort = n.TCPPort
	}
	c.Version = n.Version
	if isVerified {
		c.failures = 0
		c.lastSeen = now
		if !c.isVerified {
			c.isVerified = true
			t.updateBucket(c)
		}
	}
	return c
}

// hasSubnetRoom is CheckGlobalIPLimits and the subnet rule of
// CRoutingBin::AddContact for contact id at ip.
func (t *table) hasSubnetRoom(id wire.Hash, ip netip.Addr) bool {
	if ip.IsPrivate() {
		return true
	}
	subnet, _ := ip.Prefix(24)
	inTable := 0
	for other, c := range t.byIP {
		if c.ID != id && subnet.Contains(other) {
			inTable++
		}
	}
	index := bucketIndex(t.self, id)
	leaf := leafIndex(distance(t.self, id), index)
	b := &t.buckets[index]
	inLeaf := 0
	for _, c := range slices.Concat(b.contacts, b.replacements) {
		if c.ID != id && c.leaf == leaf && subnet.Contains(c.Addr.Addr()) {
			inLeaf++
		}
	}
	return inTable < maxTableBySubnet && inLeaf < maxLeafBySubnet
}

// contactByAddr is the contact at addr, port included.
func (t *table) contactByAddr(addr netip.AddrPort) *contact {
	if c := t.byIP[addr.Addr()]; c != nil && c.Addr == addr {
		return c
	}
	return nil
}

func (t *table) addToBucket(c *contact, isVerified bool) {
	index := bucketIndex(t.self, c.ID)
	b := &t.buckets[index]
	c.leaf = leafIndex(distance(t.self, c.ID), index)
	if b.leafSize(c.leaf) < bucketSize {
		b.contacts = append(b.contacts, c)
		return
	}
	if isVerified {
		if i := b.unverifiedIndex(c.leaf); i >= 0 {
			b.replacements = append(b.replacements, b.contacts[i])
			b.contacts[i] = c
			t.removeExcessReplacements(b)
			return
		}
	}
	b.replacements = append(b.replacements, c)
	t.removeExcessReplacements(b)
}

func (b *bucket) leafSize(leaf int) int {
	n := 0
	for _, c := range b.contacts {
		if c.leaf == leaf {
			n++
		}
	}
	return n
}

func (b *bucket) unverifiedIndex(leaf int) int {
	return slices.IndexFunc(b.contacts, func(o *contact) bool { return o.leaf == leaf && !o.isVerified })
}

func (t *table) removeExcessReplacements(b *bucket) {
	for len(b.replacements) > bucketSize {
		t.remove(b.replacements[0])
	}
}

// updateBucket moves a newly verified replacement into its leaf if there is
// room or an unverified contact to swap with.
func (t *table) updateBucket(c *contact) {
	b := &t.buckets[bucketIndex(t.self, c.ID)]
	i := slices.Index(b.replacements, c)
	if i < 0 {
		return
	}
	if b.leafSize(c.leaf) < bucketSize {
		b.replacements = slices.Delete(b.replacements, i, i+1)
		b.contacts = append(b.contacts, c)
		return
	}
	if j := b.unverifiedIndex(c.leaf); j >= 0 {
		b.replacements[i] = b.contacts[j]
		b.contacts[j] = c
	}
}

// onTimeout records an unanswered request. An unverified contact goes at once; a
// verified one after maxFailures misses, and the best replacement of its
// leaf takes its place.
func (t *table) onTimeout(addr netip.AddrPort) {
	c := t.contactByAddr(addr)
	if c == nil {
		return
	}
	c.failures++
	if c.isVerified && c.failures < maxFailures {
		return
	}
	t.remove(c)
}

func (t *table) remove(c *contact) {
	delete(t.byID, c.ID)
	delete(t.byIP, c.Addr.Addr())
	b := &t.buckets[bucketIndex(t.self, c.ID)]
	if i := slices.Index(b.replacements, c); i >= 0 {
		b.replacements = slices.Delete(b.replacements, i, i+1)
		return
	}
	i := slices.Index(b.contacts, c)
	if i < 0 {
		return
	}
	b.contacts = slices.Delete(b.contacts, i, i+1)
	best := slices.IndexFunc(b.replacements, func(o *contact) bool { return o.leaf == c.leaf && o.isVerified })
	if best < 0 {
		best = slices.IndexFunc(b.replacements, func(o *contact) bool { return o.leaf == c.leaf })
	}
	if best < 0 {
		return
	}
	b.contacts = append(b.contacts, b.replacements[best])
	b.replacements = slices.Delete(b.replacements, best, best+1)
}

// closestContacts returns up to n contacts nearest to target, nearest
// first.
func (t *table) closestContacts(target wire.Hash, n int, isVerifiedOnly bool) []*contact {
	var out []*contact
	for i := range t.buckets {
		for _, c := range t.buckets[i].contacts {
			if c.isVerified || !isVerifiedOnly {
				out = append(out, c)
			}
		}
	}
	slices.SortFunc(out, func(a, b *contact) int {
		da, db := distance(a.ID, target), distance(b.ID, target)
		return bytes.Compare(da[:], db[:])
	})
	return out[:min(n, len(out))]
}

func (t *table) verifiedCount() int {
	count := 0
	for i := range t.buckets {
		for _, c := range t.buckets[i].contacts {
			if c.isVerified {
				count++
			}
		}
	}
	return count
}

// nodes lists the bucket contacts, verified ones first, for the Durable
// State.
func (t *table) nodes() []Node {
	var verified, others []Node
	for i := range t.buckets {
		for _, c := range t.buckets[i].contacts {
			if c.isVerified {
				verified = append(verified, c.Node)
			} else {
				others = append(others, c.Node)
			}
		}
	}
	return append(verified, others...)
}

func distance(a, b wire.Hash) wire.Hash {
	var d wire.Hash
	for i := range d {
		d[i] = a[i] ^ b[i]
	}
	return d
}

func bucketIndex(self, id wire.Hash) int {
	d := distance(self, id)
	for i, b := range d {
		for bit := range 8 {
			if b&(0x80>>bit) != 0 {
				return i*8 + bit
			}
		}
	}
	return 127
}

func leafCount(index int) int {
	if index == 0 {
		return 8
	}
	return 5
}

// leafIndex numbers the leaf of bucket index that distance d falls in by
// the three bits after the leading 1: bucket 0 uses them as they are; other
// buckets keep 000 and 001 apart and merge the pairs 01x, 10x and 11x.
func leafIndex(d wire.Hash, index int) int {
	bits := bitsAt(d, index+1, 3)
	if index == 0 || bits < 0b010 {
		return int(bits)
	}
	return int(bits>>1) + 1
}

// bitsAt is the n bits of h from bit position from on, most significant
// first; bits past the end read as 0.
func bitsAt(h wire.Hash, from, n int) byte {
	var v byte
	for p := from; p < from+n; p++ {
		v <<= 1
		if p < 128 && h[p/8]&(0x80>>(p%8)) != 0 {
			v |= 1
		}
	}
	return v
}

// buildRandomID returns an ID that lands in the given leaf of bucket index
// of self.
func buildRandomID(self wire.Hash, index, leaf int, rng *rand.Rand) wire.Hash {
	var d wire.Hash
	for i := range d {
		d[i] = byte(rng.UintN(256))
	}
	bits, n := byte(leaf), 3
	if index > 0 && leaf >= 2 {
		bits, n = byte(leaf-1), 2
	}
	setBit(&d, index, true)
	for p := range index {
		setBit(&d, p, false)
	}
	for k := range n {
		setBit(&d, index+1+k, bits&(1<<(n-1-k)) != 0)
	}
	return distance(self, d)
}

func setBit(h *wire.Hash, p int, isSet bool) {
	if p >= 128 {
		return
	}
	mask := byte(0x80 >> (p % 8))
	if isSet {
		h[p/8] |= mask
	} else {
		h[p/8] &^= mask
	}
}
