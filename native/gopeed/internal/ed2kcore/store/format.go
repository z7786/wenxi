package store

import (
	"bytes"
	"encoding/json"
	"net/netip"
	"slices"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// version is Kelpie's state.json format; goed2k wrote versions up to 3.
const version = 4

type stateFile struct {
	Version    int            `json:"version"`
	UserHash   hashText       `json:"userHash"`
	PrivateKey []byte         `json:"privateKey,omitempty"`
	Kad        kadFile        `json:"kad"`
	Credits    []creditFile   `json:"credits"`
	Transfers  []transferFile `json:"transfers"`
	Servers    []serverFile   `json:"servers"`
}

type serverFile struct {
	Endpoint           netip.AddrPort `json:"endpoint,omitzero"`
	Host               string         `json:"host,omitempty"`
	Port               uint16         `json:"port,omitempty"`
	Failures           uint32         `json:"failures"`
	Ping               uint32         `json:"ping"`
	Users              uint32         `json:"users"`
	Files              uint32         `json:"files"`
	SoftFiles          uint32         `json:"softFiles"`
	UDPFlags           uint32         `json:"udpFlags"`
	TCPObfuscationPort uint16         `json:"tcpObfuscationPort"`
	UDPObfuscationPort uint16         `json:"udpObfuscationPort"`
	PingedAt           time.Time      `json:"pingedAt"`
	UDPKey             uint32         `json:"udpKey,omitempty"`
	UDPKeyIP           netip.Addr     `json:"udpKeyIP,omitzero"`
}

type kadFile struct {
	ID           hashText      `json:"id"`
	IsFirewalled bool          `json:"isFirewalled"`
	UDPKey       uint32        `json:"udpKey,omitempty"`
	Nodes        []kadNodeFile `json:"nodes"`
}

type kadNodeFile struct {
	ID      hashText       `json:"id"`
	Addr    netip.AddrPort `json:"addr"`
	TCPPort uint16         `json:"tcpPort,omitempty"`
	Version byte           `json:"version"`
}

type creditFile struct {
	UserHash   hashText  `json:"userHash"`
	Uploaded   uint64    `json:"uploaded"`
	Downloaded uint64    `json:"downloaded"`
	PublicKey  []byte    `json:"publicKey,omitempty"`
	LastSeen   time.Time `json:"lastSeen"`
}

type transferFile struct {
	Hash          hashText           `json:"hash"`
	Size          int64              `json:"size"`
	File          string             `json:"file"`
	PartHashes    []hashText         `json:"partHashes"`
	VerifiedParts []bool             `json:"verifiedParts"`
	WrittenBlocks []blockFile        `json:"writtenBlocks"`
	PartialBlocks []partialBlockFile `json:"partialBlocks"`
	Uploaded      uint64             `json:"uploaded"`
	Created       time.Time          `json:"created"`
}

type blockFile struct {
	Part  int `json:"part"`
	Index int `json:"index"`
}

type partialBlockFile struct {
	Part  int   `json:"part"`
	Index int   `json:"index"`
	Size  int64 `json:"size"`
}

// hashText is a wire.Hash written as uppercase hex, with "" for the zero hash
// as goed2k wrote it.
type hashText wire.Hash

func (h hashText) MarshalText() ([]byte, error) {
	if h == (hashText{}) {
		return nil, nil
	}
	return []byte(wire.Hash(h).String()), nil
}

func (h *hashText) UnmarshalText(text []byte) error {
	if len(bytes.TrimSpace(text)) == 0 {
		*h = hashText{}
		return nil
	}
	hash, err := wire.ParseHash(string(text))
	*h = hashText(hash)
	return err
}

func toFile(state State) stateFile {
	file := stateFile{
		Version:    version,
		UserHash:   hashText(state.Identity.UserHash),
		PrivateKey: state.Identity.PrivateKey,
		Kad:        kadFile{ID: hashText(state.Kad.ID), IsFirewalled: state.Kad.IsFirewalled, UDPKey: state.Kad.UDPKey, Nodes: []kadNodeFile{}},
		Credits:    []creditFile{},
		Transfers:  []transferFile{},
		Servers:    []serverFile{},
	}
	for _, server := range state.Servers {
		file.Servers = append(file.Servers, serverFile(server))
	}
	for _, node := range state.Kad.Nodes {
		file.Kad.Nodes = append(file.Kad.Nodes, kadNodeFile{ID: hashText(node.ID), Addr: node.Addr, TCPPort: node.TCPPort, Version: node.Version})
	}
	for hash, credit := range state.Credits {
		file.Credits = append(file.Credits, creditFile{
			UserHash:   hashText(hash),
			Uploaded:   credit.Uploaded,
			Downloaded: credit.Downloaded,
			PublicKey:  credit.PublicKey,
			LastSeen:   credit.LastSeen,
		})
	}
	slices.SortFunc(file.Credits, func(a, b creditFile) int { return bytes.Compare(a.UserHash[:], b.UserHash[:]) })
	for hash, transfer := range state.Transfers {
		entry := transferFile{
			Hash:          hashText(hash),
			Size:          transfer.Size,
			File:          transfer.File,
			PartHashes:    []hashText{},
			VerifiedParts: transfer.VerifiedParts,
			WrittenBlocks: []blockFile{},
			PartialBlocks: []partialBlockFile{},
			Uploaded:      transfer.Uploaded,
			Created:       transfer.Created,
		}
		for _, part := range transfer.PartHashes {
			entry.PartHashes = append(entry.PartHashes, hashText(part))
		}
		for _, block := range transfer.WrittenBlocks {
			part, index := block.Part(), block.Index()
			if block == piece.BlockOf(transfer.Size, part, index) {
				entry.WrittenBlocks = append(entry.WrittenBlocks, blockFile{Part: part, Index: index})
			} else {
				entry.PartialBlocks = append(entry.PartialBlocks, partialBlockFile{Part: part, Index: index, Size: block.End - block.Begin})
			}
		}
		file.Transfers = append(file.Transfers, entry)
	}
	slices.SortFunc(file.Transfers, func(a, b transferFile) int { return bytes.Compare(a.Hash[:], b.Hash[:]) })
	return file
}

func parse(raw []byte) (State, error) {
	var file stateFile
	if err := json.Unmarshal(raw, &file); err != nil {
		return State{}, err
	}
	state := buildState()
	state.Identity = Identity{UserHash: wire.Hash(file.UserHash), PrivateKey: file.PrivateKey}
	state.Kad = Kad{ID: wire.Hash(file.Kad.ID), IsFirewalled: file.Kad.IsFirewalled, UDPKey: file.Kad.UDPKey}
	for _, node := range file.Kad.Nodes {
		state.Kad.Nodes = append(state.Kad.Nodes, KadNode{ID: wire.Hash(node.ID), Addr: node.Addr, TCPPort: node.TCPPort, Version: node.Version})
	}
	for _, credit := range file.Credits {
		state.Credits[wire.Hash(credit.UserHash)] = Credit{
			Uploaded:   credit.Uploaded,
			Downloaded: credit.Downloaded,
			PublicKey:  credit.PublicKey,
			LastSeen:   credit.LastSeen,
		}
	}
	for _, entry := range file.Transfers {
		transfer := Transfer{
			Size:          entry.Size,
			File:          entry.File,
			VerifiedParts: piece.Set(entry.VerifiedParts),
			Uploaded:      entry.Uploaded,
			Created:       entry.Created,
		}
		for _, part := range entry.PartHashes {
			transfer.PartHashes = append(transfer.PartHashes, wire.Hash(part))
		}
		for _, block := range entry.WrittenBlocks {
			transfer.WrittenBlocks = append(transfer.WrittenBlocks, piece.BlockOf(entry.Size, block.Part, block.Index))
		}
		for _, block := range entry.PartialBlocks {
			begin := piece.BlockOf(entry.Size, block.Part, block.Index).Begin
			transfer.WrittenBlocks = append(transfer.WrittenBlocks, piece.Block{Begin: begin, End: begin + block.Size})
		}
		state.Transfers[wire.Hash(entry.Hash)] = transfer
	}
	for _, server := range file.Servers {
		state.Servers = append(state.Servers, Server(server))
	}
	return state, nil
}
