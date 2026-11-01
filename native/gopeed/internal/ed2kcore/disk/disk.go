// Package disk is the engine's seam for files: those it downloads and seeds,
// the server and node lists it reads, and the trace it writes.
package disk

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"syscall"
)

type Disk interface {
	Open(path string, mode Mode) (File, error)
	// Probe reports a missing path as nil info and nil error.
	Probe(path string) (*Info, error)
}

// Info is what Probe tells of an existing path.
type Info struct {
	Size     int64
	IsFolder bool
}

type File interface {
	io.ReaderAt
	io.WriterAt
	Sync() error
	Close() error
}

type Mode int

const (
	// Read opens an existing file for seeding, so a read-only file can be shared.
	Read Mode = iota
	// Create opens a file for reading and writing, creating it when missing.
	Create
)

// IsFull reports whether err means the disk has no space left.
func IsFull(err error) bool {
	return errors.Is(err, syscall.ENOSPC) || isWindowsFull(err)
}

// Real is the Disk of the running process.
type Real struct{}

func (Real) Open(path string, mode Mode) (File, error) {
	if mode == Read {
		return os.Open(path)
	}
	return os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o644)
}

func (Real) Probe(path string) (*Info, error) {
	info, err := os.Stat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil, nil
	case err != nil:
		return nil, err
	}
	return &Info{Size: info.Size(), IsFolder: info.IsDir()}, nil
}
