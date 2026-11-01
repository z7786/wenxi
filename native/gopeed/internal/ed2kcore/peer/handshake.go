package peer

import (
	"bytes"
	"fmt"
	"net/netip"
	"strings"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/identity"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

const clientName = "Kelpie"

// Versions Kelpie implements, as eMule numbers them.
const (
	udpVersion             = 4 // UDPVERSION: UDP reask with part status
	dataCompressionVersion = 1
	emuleProtocol          = 1 // EMULE_PROTOCOL
)

// buildHello names our version in CT_MOD_VERSION as well, since we send
// CT_MOD_MISCOPTIONS: eMuleAI bans a sender of that tag that carries no
// readable mod version (aMule PeerCapabilities.h:216-236).
func (s *Session) buildHello() client.Hello {
	return client.Hello{
		UserHash: s.cfg.Self.UserHash,
		ClientID: s.cfg.ClientID,
		Port:     s.cfg.Port,
		Server:   s.cfg.Server,
		Name:     clientName,
		Version:  client.EDonkeyVersion,
		ModName:  clientName + " " + strings.TrimPrefix(s.cfg.Version, "v"),
		UDPPort:  s.cfg.UDPPort,
		KadPort:  s.cfg.KadPort,
		Buddy:    s.cfg.Buddy,
		Misc1: client.MiscOptions1{
			AICHVersion:             aichVersion,
			IsUnicode:               true,
			UDPVersion:              udpVersion,
			DataCompressionVersion:  dataCompressionVersion,
			SecureIdentVersion:      s.identSupport(),
			ExtendedRequestsVersion: client.ExtendedRequestsVersion,
			IsSharedFilesHidden:     true,
			HasMultiPacket:          true,
		},
		Misc2: client.MiscOptions2{
			KadVersion:           s.cfg.KadVersion,
			HasDirectUDPCallback: s.cfg.HasDirectCallback,
			HasLargeFiles:        true,
			HasExtMultiPacket:    true,
			HasFileIdentifiers:   true,
			HasSourceExchange2:   true,
			CanCrypt:             true,
			IsCryptRequested:     true,
		},
		EmuleVersion: wire.ToEmuleVersion(s.cfg.Version),
		ModMisc:      client.ModMiscExtendedSources | client.ModMiscExtendedSourcesSkipTags,
		YourIP:       s.remote.Addr(),
	}
}

// identSupport is SecIdent::SupportedVersions (aMule SecIdentPolicy.h): a
// v2 signature covers an IPv4 address both ends must agree on, so a peer
// reached over IPv6 is offered v1 only.
func (s *Session) identSupport() byte {
	if s.remote.Addr().Is4() {
		return identity.Support
	}
	return identity.Support &^ 2
}

// greeting is how far the exchange of Hellos got.
type greeting byte

const (
	// awaitingHello: the peer opened the connection and owes us its Hello.
	awaitingHello greeting = iota
	// awaitingHelloAnswer: we opened it and sent our Hello.
	awaitingHelloAnswer
	handshaken
	// connecting: we are still dialling; the session has no Config yet.
	connecting
)

func (s *Session) onGreeting(p wire.Packet, out *Output) {
	var hello client.Hello
	switch p := p.(type) {
	case client.EmuleInfo:
		// Shareaza and MLDonkey send it before their HelloAnswer.
		s.sendEmuleInfoAnswer(out)
		s.earlyEmuleInfo = &p
		return
	case client.Hello:
		if s.greeting != awaitingHello {
			out.Close = closeProtocol
			return
		}
		hello = p
		out.send(client.HelloAnswer(s.buildHello()))
	case client.HelloAnswer:
		if s.greeting != awaitingHelloAnswer {
			out.Close = closeProtocol
			return
		}
		hello = client.Hello(p)
	default:
		out.Close = closeProtocol
		return
	}
	s.setHello(hello)
	if s.earlyEmuleInfo != nil {
		s.setEmuleInfo(*s.earlyEmuleInfo)
		s.earlyEmuleInfo = nil
	}
	s.greeting = handshaken
	// The engine attaches a connection's files to their transfers on
	// HandshakeCompleted, so the files the peer cannot serve go first.
	s.rejectLargeFiles(out)
	out.add(HandshakeCompleted{YourIP: hello.YourIP})
	s.sendIdentState(out)
	for _, d := range s.down.files {
		s.sendFileRequest(d, out)
	}
	s.startFirstFile(out)
}

func (s *Session) setHello(h client.Hello) {
	s.caps = Capabilities{
		UserHash:           h.UserHash,
		ClientID:           toLowID(h.ClientID, s.remote.Addr()),
		Port:               h.Port,
		Server:             h.Server,
		UDPPort:            h.UDPPort,
		KadPort:            h.KadPort,
		UDPVersion:         h.Misc1.UDPVersion,
		KadVersion:         h.Misc2.KadVersion,
		IPv6:               toPublicIPv6(h.IPv6),
		MuleVersion:        toMuleVersion(h.EmuleVersion),
		HasSourceExchange2: h.Misc2.HasSourceExchange2,
		HasDirectCallback:  h.Misc2.HasDirectUDPCallback,
		CryptOptions:       toCryptOptions(h.Misc2),
		Software:           toSoftware(h.EmuleVersion, h.ModName),
	}
	s.features = features{
		isEmule:                    h.EmuleVersion != 0,
		canCompress:                h.Misc1.DataCompressionVersion > 0,
		secureIdent:                h.Misc1.SecureIdentVersion,
		extendedRequests:           h.Misc1.ExtendedRequestsVersion,
		hasMultiPacket:             h.Misc1.HasMultiPacket,
		hasExtMultiPacket:          h.Misc2.HasExtMultiPacket,
		hasFileIdentifiers:         h.Misc2.HasFileIdentifiers,
		hasLargeFiles:              h.Misc2.HasLargeFiles,
		hasExtendedSources:         h.ModMisc&client.ModMiscExtendedSources != 0,
		hasExtendedSourcesSkipTags: h.ModMisc&client.ModMiscExtendedSourcesSkipTags != 0,
		hasAICH:                    h.Misc1.AICHVersion&aichVersion != 0,
	}
}

// toLowID is the peer's LowID, or 0 when it is reached at the address it
// connected from. Like aMule (BaseClient.cpp:772), an ID of 0 is a HighID
// peer with no server, and an ID equal to that address is a HighID such as
// a.b.c.0, whose ID looks like a LowID.
func toLowID(id uint32, remote netip.Addr) uint32 {
	if !wire.IsLowID(id) || id == wire.ToClientID(remote) {
		return 0
	}
	return id
}

// toPublicIPv6 keeps an IPv6 address the peer announced for itself only
// when others can reach it: it goes on to them in Source Exchange
// (ipv6-spec §3.2; aMule IsUsableTagIdentity).
func toPublicIPv6(addr netip.Addr) netip.Addr {
	if !addr.Is6() || addr.Is4In6() || !wire.IsPublic(addr) {
		return netip.Addr{}
	}
	return addr
}

// toSoftware names a client from CT_EMULE_VERSION, laid out as
// wire.ToEmuleVersion describes, and CT_MOD_VERSION, as aMule's client list
// does (ReGetClientSoft, BaseClient.cpp:2102; ClientVersionString.cpp): the
// mule family counts its update as a number, eMule and the rest as a letter
// from 'a'. A client it does not know goes by its mod version alone.
func toSoftware(emuleVersion uint32, modName string) string {
	if emuleVersion == 0 {
		return ""
	}
	major, minor, update := emuleVersion>>17&0x7F, emuleVersion>>10&0x7F, emuleVersion>>7&0x07
	isNumbered := true
	var name string
	switch emuleVersion >> 24 {
	case 0:
		name, isNumbered = "eMule", false
	case 1:
		name, isNumbered = "cDonkey", false
	case 2:
		name = "xMule"
	case 3:
		name = "aMule"
	case 4, 0x28, 0x44:
		name, isNumbered = "Shareaza", false
	case 5:
		name, isNumbered = "eMule Plus", false
	case 6:
		name = "Hydranode"
	case 0x0A, 0x34, 0x98:
		name = "MLDonkey"
	case 0x14:
		name, isNumbered = "lphant", false
	case 0x4B:
		name = clientName
	default:
		return modName
	}
	software := fmt.Sprintf("%s %d.%d%c", name, major, minor, 'a'+update)
	if isNumbered {
		software = fmt.Sprintf("%s %d.%d.%d", name, major, minor, update)
	}
	if name == "eMule" && modName != "" {
		software += " [" + modName + "]"
	}
	return software
}

func toMuleVersion(emuleVersion uint32) byte {
	if emuleVersion == 0 {
		return 0
	}
	return 0x99
}

// toCryptOptions drops a request without support and a requirement
// without request, as eMule reads the Hello.
func toCryptOptions(m client.MiscOptions2) byte {
	var options byte
	if m.CanCrypt {
		options |= wire.CryptSupported
		if m.IsCryptRequested {
			options |= wire.CryptRequested
			if m.IsCryptRequired {
				options |= wire.CryptRequired
			}
		}
	}
	return options
}

// onEmuleInfo serves clients older than the Hello capability tags; a peer
// that sent CT_EMULE_VERSION already told us everything.
func (s *Session) onEmuleInfo(p client.EmuleInfo, out *Output) {
	s.sendEmuleInfoAnswer(out)
	s.setEmuleInfo(p)
}

func (s *Session) sendEmuleInfoAnswer(out *Output) {
	// The answer splits the same fields CT_EMULE_VERSION packs.
	version := wire.ToEmuleVersion(s.cfg.Version)
	major, minor := version>>17&0x7F, version>>10&0x7F
	tag := func(id byte, v uint32) wire.Tag { return wire.Tag{Type: wire.TagUint32, ID: id, Uint: uint64(v)} }
	out.send(client.EmuleInfoAnswer{
		Version:         byte(major<<4 | minor&0x0F),
		ProtocolVersion: emuleProtocol,
		Tags: []wire.Tag{
			tag(client.InfoCompression, dataCompressionVersion),
			tag(client.InfoUDPVersion, udpVersion),
			tag(client.InfoUDPPort, uint32(s.cfg.UDPPort)),
			tag(client.InfoExtendedRequest, client.ExtendedRequestsVersion),
			tag(client.InfoCompatibleClient, version>>24),
			tag(client.InfoFeatures, uint32(s.identSupport())),
		},
	})
}

func (s *Session) setEmuleInfo(p client.EmuleInfo) {
	if s.features.isEmule {
		return
	}
	s.features.isEmule = true
	s.caps.MuleVersion = p.Version
	var compatible uint32
	for _, t := range p.Tags {
		switch t.ID {
		case client.InfoCompatibleClient:
			compatible = uint32(t.Uint)
		case client.InfoCompression:
			s.features.canCompress = t.Uint > 0
		case client.InfoUDPVersion:
			s.caps.UDPVersion = byte(t.Uint)
		case client.InfoUDPPort:
			s.caps.UDPPort = uint16(t.Uint)
		case client.InfoExtendedRequest:
			s.features.extendedRequests = byte(t.Uint)
		case client.InfoFeatures:
			s.features.secureIdent = byte(t.Uint) & 0x03
		}
	}
	// The version byte holds 0.xy as x and y in its nibbles (aMule
	// BaseClient.cpp:2174).
	if p.Version != 0 {
		minor := uint32(p.Version>>4)*10 + uint32(p.Version&0x0F)
		s.caps.Software = toSoftware(compatible<<24|minor<<10, "")
	}
}

// identState runs Secure User Identification in both directions: we prove
// ourselves to the peer, and the peer proves itself to us.
type identState struct {
	challenge uint32
	peerKey   []byte
	// pending is the peer's challenge we can sign only once its key arrives.
	pending *pendingSignature
}

type pendingSignature struct {
	challenge uint32
	kind      identity.IPKind
}

// sendIdentState always asks for the key too: the engine compares the key
// that signed against the one it stored, so the session needs no ledger.
func (s *Session) sendIdentState(out *Output) {
	if s.features.secureIdent == 0 {
		return
	}
	for s.ident.challenge == 0 {
		s.ident.challenge = s.cfg.Random.Uint32()
	}
	out.send(client.SecureIdentState{State: client.SecureIdentNeedsKeyAndSignature, Challenge: s.ident.challenge})
}

// onIdentState signs no v2 challenge over IPv6, where the two ends cannot
// agree on the IPv4 address it covers (SecIdent::SignatureVersion).
func (s *Session) onIdentState(p client.SecureIdentState, out *Output) {
	reply := identity.BuildReply(identity.State(p.State), s.features.secureIdent, wire.IsLowID(s.cfg.ClientID))
	if reply.IPKind != 0 && !s.remote.Addr().Is4() {
		return
	}
	if reply.ShouldSendKey {
		out.send(client.PublicKey{Key: s.cfg.Self.PublicKey()})
	}
	switch {
	case !reply.ShouldSign:
	case s.ident.peerKey != nil:
		s.sendSignature(p.Challenge, reply.IPKind, out)
	default:
		s.ident.pending = &pendingSignature{p.Challenge, reply.IPKind}
	}
}

func (s *Session) sendSignature(value uint32, kind identity.IPKind, out *Output) {
	challenge := identity.Challenge{Value: value, IPKind: kind, SignerIP: wire.ToAddr(s.cfg.ClientID), VerifierIP: s.remote.Addr()}
	signature := s.cfg.Self.BuildSignature(s.ident.peerKey, challenge)
	out.send(client.Signature{Signature: signature, IPKind: byte(kind)})
}

func (s *Session) onPublicKey(p client.PublicKey, out *Output) {
	if s.ident.peerKey != nil {
		return
	}
	s.ident.peerKey = bytes.Clone(p.Key)
	if pending := s.ident.pending; pending != nil {
		s.ident.pending = nil
		s.sendSignature(pending.challenge, pending.kind, out)
	}
}

func (s *Session) onSignature(p client.Signature, out *Output) {
	if s.ident.challenge == 0 {
		return
	}
	challenge := identity.Challenge{Value: s.ident.challenge, IPKind: identity.IPKind(p.IPKind), SignerIP: s.remote.Addr(), VerifierIP: s.toPublicIP()}
	s.ident.challenge = 0
	if s.ident.peerKey != nil && identity.MatchSignature(s.ident.peerKey, p.Signature, s.cfg.Self.PublicKey(), challenge) {
		out.add(Identified{PublicKey: s.ident.peerKey})
	}
}

func (s *Session) toPublicIP() netip.Addr {
	if !wire.IsLowID(s.cfg.ClientID) {
		return wire.ToAddr(s.cfg.ClientID)
	}
	return s.cfg.PublicIP
}
