// Derived from goed2k client_state.go and protocol/transfer_resume_data.go.
package store

import (
	"encoding/json"
	"net/netip"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// goed2kState is the part of goed2k's ClientState (client_state.go, version
// 3) that Kelpie keeps. Paused flags, upload priorities, peers, the server
// address and friend slots are dropped: Kelpie resumes nothing on its own
// (ADR-0004) and finds sources again.
type goed2kState struct {
	UserAgent hashText `json:"user_agent"`
	Transfers []struct {
		Hash       hashText `json:"hash"`
		Size       int64    `json:"size"`
		CreateTime int64    `json:"create_time"`
		TargetPath string   `json:"target_path"`
		ResumeData *struct {
			Hashes           []hashText    `json:"hashes"`
			Pieces           []bool        `json:"pieces"`
			DownloadedBlocks []goed2kBlock `json:"downloaded_blocks"`
		} `json:"resume_data"`
	} `json:"transfers"`
	Credits []struct {
		PeerHash   hashText
		Uploaded   uint64
		Downloaded uint64
	} `json:"credits"`
	DHT *struct {
		SelfID     hashText `json:"self_id"`
		Firewalled bool     `json:"firewalled"`
		Nodes      []struct {
			ID      hashText `json:"id"`
			Addr    string   `json:"addr"`
			Version byte     `json:"version"`
		} `json:"nodes"`
	} `json:"dht"`
}

// goed2kBlock is a 190 KiB block of goed2k (goed2kBlockSize).
type goed2kBlock struct {
	PieceIndex int
	PieceBlock int
}

func parseGoed2k(raw []byte) (State, error) {
	var old goed2kState
	if err := json.Unmarshal(raw, &old); err != nil {
		return State{}, err
	}
	state := buildState()
	state.Identity.UserHash = wire.Hash(old.UserAgent)
	for _, credit := range old.Credits {
		state.Credits[wire.Hash(credit.PeerHash)] = Credit{Uploaded: credit.Uploaded, Downloaded: credit.Downloaded}
	}
	if old.DHT != nil {
		state.Kad.ID = wire.Hash(old.DHT.SelfID)
		state.Kad.IsFirewalled = old.DHT.Firewalled
		for _, node := range old.DHT.Nodes {
			addr, err := netip.ParseAddrPort(node.Addr)
			if err != nil {
				continue
			}
			state.Kad.Nodes = append(state.Kad.Nodes, KadNode{
				ID:      wire.Hash(node.ID),
				Addr:    netip.AddrPortFrom(addr.Addr().Unmap(), addr.Port()),
				Version: node.Version,
			})
		}
	}
	for _, entry := range old.Transfers {
		if entry.TargetPath == "" {
			continue
		}
		transfer := Transfer{Size: entry.Size, File: entry.TargetPath, Created: time.UnixMilli(entry.CreateTime).UTC()}
		if resume := entry.ResumeData; resume != nil {
			for _, part := range resume.Hashes {
				transfer.PartHashes = append(transfer.PartHashes, wire.Hash(part))
			}
			transfer.VerifiedParts = piece.Set(resume.Pieces)
			written := map[goed2kBlock]bool{}
			for _, block := range resume.DownloadedBlocks {
				written[block] = true
			}
			transfer.WrittenBlocks = toWrittenBlocks(entry.Size, written)
		}
		state.Transfers[wire.Hash(entry.Hash)] = transfer
	}
	return state, nil
}

// goed2k wrote 190 KiB blocks; Kelpie counts eMule's 180 KiB blocks. A Kelpie
// block counts as written only when goed2k blocks cover every byte of it.
const goed2kBlockSize = 190 * 1024

func toWrittenBlocks(size int64, written map[goed2kBlock]bool) []piece.Block {
	var blocks []piece.Block
	for part := range piece.PartCount(size) {
		partBegin := piece.PartRange(size, part).Begin
		for index := range piece.BlockCount(size, part) {
			block := piece.BlockOf(size, part, index)
			isCovered := true
			for old := (block.Begin - partBegin) / goed2kBlockSize; old <= (block.End-1-partBegin)/goed2kBlockSize; old++ {
				isCovered = isCovered && written[goed2kBlock{part, int(old)}]
			}
			if isCovered {
				blocks = append(blocks, block)
			}
		}
	}
	return blocks
}
