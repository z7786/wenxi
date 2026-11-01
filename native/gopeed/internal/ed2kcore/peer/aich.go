package peer

import (
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire/client"
)

// aichVersion is the AICH version in MiscOptions1; aMule reads bit 0 as
// support (updownclient.h:389).
const aichVersion = 1

// RootReceived carries the AICH root the peer reported for File.
type RootReceived struct {
	File wire.Hash
	Root wire.AICHHash
}

// RecoveryReceived carries the recovery data the peer sent for Part of
// File, not yet checked against any root.
type RecoveryReceived struct {
	File    wire.Hash
	Part    int
	Root    wire.AICHHash
	Entries []client.AICHEntry
}

// RecoveryFailed: the peer cannot give the recovery data asked for File.
type RecoveryFailed struct{ File wire.Hash }

// TreeWanted: a peer asked about the AICH tree of File, a complete file of
// ours whose Share has no Tree yet. The engine builds it.
type TreeWanted struct{ File wire.Hash }

func (RootReceived) isEvent()     {}
func (RecoveryReceived) isEvent() {}
func (RecoveryFailed) isEvent()   {}
func (TreeWanted) isEvent()       {}

type recoveryRequest struct {
	file wire.Hash
	part int
}

// RequestRecovery asks the peer for the recovery data of part of file under
// root. Like aMule (m_fAICHRequested, DownloadClient.cpp:1613) a session
// has one request out at a time; another fails at once.
func (s *Session) RequestRecovery(file wire.Hash, part int, root wire.AICHHash) Output {
	var out Output
	if s.recovery != nil {
		out.add(RecoveryFailed{File: file})
		return out
	}
	s.recovery = &recoveryRequest{file: file, part: part}
	out.send(client.AICHRequest{Hash: file, Part: uint16(part), Root: root})
	return out
}

func (s *Session) onRoot(file wire.Hash, root wire.AICHHash, out *Output) {
	if s.downloadByHash(file) != nil {
		out.add(RootReceived{File: file, Root: root})
	}
}

// onRecoveryAnswer closes on an answer nobody asked for, as aMule does
// (DownloadClient.cpp:1626-1628).
func (s *Session) onRecoveryAnswer(p client.AICHAnswer, out *Output) {
	request := s.recovery
	if request == nil {
		out.Close = closeProtocol
		return
	}
	s.recovery = nil
	if !p.HasData || p.Hash != request.file || int(p.Part) != request.part {
		out.add(RecoveryFailed{File: request.file})
		return
	}
	out.add(RecoveryReceived{File: p.Hash, Part: request.part, Root: p.Root, Entries: p.Entries})
}

// onRootRequest answers OP_AICHFILEHASHREQ, alone or inside a MultiPacket:
// our root, or false. aMule answers only peers that support AICH
// (ClientTCPSocket.cpp:1078).
func (s *Session) onRootRequest(file wire.Hash, share Share, out *Output) (client.AICHFileHashAnswer, bool) {
	if !s.features.hasAICH {
		return client.AICHFileHashAnswer{}, false
	}
	if share.Tree == nil {
		s.requestTree(file, share, out)
		return client.AICHFileHashAnswer{}, false
	}
	return client.AICHFileHashAnswer{Hash: file, Root: share.Tree.Root()}, true
}

func (s *Session) requestTree(file wire.Hash, share Share, out *Output) {
	if share.Parts.IsFull() {
		out.add(TreeWanted{File: file})
	}
}

// onRecoveryRequest follows ProcessAICHRequest (DownloadClient.cpp:1666-1716):
// the data for a part longer than one block under the root we have, or the
// bare hash to say no.
func (s *Session) onRecoveryRequest(p client.AICHRequest, out *Output) {
	answer := client.AICHAnswer{Hash: p.Hash}
	share, ok := s.cfg.ShareByHash(p.Hash)
	part := int(p.Part)
	switch {
	case !ok:
	case share.Tree == nil:
		s.requestTree(p.Hash, share, out)
	case share.Tree.Root() == p.Root && part < piece.PartCount(share.Size) && piece.BlockCount(share.Size, part) > 1:
		answer = client.AICHAnswer{
			Hash:          p.Hash,
			HasData:       true,
			Part:          p.Part,
			Root:          p.Root,
			Entries:       share.Tree.BuildRecovery(part),
			HasLongIdents: share.Size > largeFileSize,
		}
	}
	out.send(answer)
}
