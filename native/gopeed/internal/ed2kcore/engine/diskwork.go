package engine

import (
	"io"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/aich"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/disk"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// hashChunk is how much a disk worker reads at a time while hashing.
const hashChunk = 1 << 20

type jobKind int

const (
	jobWrite jobKind = iota
	jobRead
	jobHashPart
	jobHashFile
	jobSync
	jobHashBlocks
	jobHashTree
)

// diskJob is work for a disk worker on the bytes of block. run routes the
// result back; a result for a run that has ended is dropped.
type diskJob struct {
	kind  jobKind
	run   RunID
	file  disk.File
	block piece.Block
	data  []byte
	part  int
	conn  uint64
	hash  wire.Hash
}

type diskDone struct {
	job        diskJob
	data       []byte
	digest     wire.Hash
	partHashes []wire.Hash
	leaves     []wire.AICHHash
	err        error
}

func (e *Engine) runDiskWorker(jobs <-chan diskJob) {
	for {
		select {
		case job := <-jobs:
			if !e.send(e.ctx, runDiskJob(job)) {
				return
			}
		case <-e.ctx.Done():
			return
		}
	}
}

func runDiskJob(job diskJob) diskDone {
	done := diskDone{job: job}
	switch job.kind {
	case jobWrite:
		_, done.err = job.file.WriteAt(job.data, job.block.Begin)
	case jobRead:
		done.data = make([]byte, job.block.End-job.block.Begin)
		_, done.err = loadAt(job.file, done.data, job.block.Begin)
	case jobHashPart:
		var hasher piece.MD4
		done.err = loadRange(&hasher, job.file, job.block.Begin, job.block.End)
		done.digest = hasher.Digest()
	case jobHashFile:
		var hasher piece.FileHasher
		var leaves aich.Hasher
		done.err = loadRange(io.MultiWriter(&hasher, &leaves), job.file, job.block.Begin, job.block.End)
		done.digest, done.partHashes, done.leaves = hasher.FileHash(), hasher.PartHashes(), leaves.Leaves()
	case jobHashBlocks, jobHashTree:
		var leaves aich.Hasher
		done.err = loadRange(&leaves, job.file, job.block.Begin, job.block.End)
		done.leaves = leaves.Leaves()
	case jobSync:
		done.err = job.file.Sync()
	}
	return done
}

func loadAt(file disk.File, b []byte, offset int64) (int, error) {
	n, err := file.ReadAt(b, offset)
	if n == len(b) {
		return n, nil
	}
	if err == nil || err == io.EOF {
		err = io.ErrUnexpectedEOF
	}
	return n, err
}

func loadRange(w io.Writer, file disk.File, begin, end int64) error {
	buf := make([]byte, min(hashChunk, end-begin))
	for offset := begin; offset < end; {
		chunk := buf[:min(int64(len(buf)), end-offset)]
		if _, err := loadAt(file, chunk, offset); err != nil {
			return err
		}
		w.Write(chunk)
		offset += int64(len(chunk))
	}
	return nil
}

func (e *Engine) onDiskDone(d diskDone) {
	e.disk.onDone()
	if d.job.kind == jobRead {
		e.onBlockRead(d)
		return
	}
	r := e.runByID(d.job.run)
	if r == nil {
		return
	}
	if d.job.kind == jobHashFile {
		if d.err != nil {
			e.stopRun(r, toFileError(d.err))
			return
		}
		r.tree = aich.BuildTree(r.file.Size, d.leaves)
		e.onFileHashed(r, d.partHashes, d.digest)
		return
	}
	if d.job.kind == jobSync {
		var err *Error
		if d.err != nil {
			err = toFileError(d.err)
		}
		e.stopRun(r, err)
		return
	}
	if r.transfer == nil {
		return
	}
	if d.err != nil {
		r.transfer.OnDiskFailed(disk.IsFull(d.err), d.err.Error())
		return
	}
	now := e.now()
	switch d.job.kind {
	case jobWrite:
		e.runTransferActions(r, r.transfer.OnBlockWritten(d.job.block))
	case jobHashPart:
		e.runTransferActions(r, r.transfer.OnPartHashed(d.job.part, d.digest, now))
		e.refreshShare(r)
	case jobHashBlocks:
		e.runTransferActions(r, r.transfer.OnBlocksHashed(d.job.part, d.leaves, now))
	case jobHashTree:
		r.tree = aich.BuildTree(r.file.Size, d.leaves)
		e.refreshShare(r)
	}
}
