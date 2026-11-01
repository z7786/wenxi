// modify from github.com/anacrolix/torrent/storage/file_piece.go

package bt

import (
	"github.com/GopeedLab/gopeed/internal/outputfile"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
	"io"
	"log"
)

type filePieceImpl struct {
	*fileTorrentImpl
	p metainfo.Piece
	io.WriterAt
	io.ReaderAt
}

var _ storage.PieceImpl = (*filePieceImpl)(nil)

func (fs *filePieceImpl) pieceKey() metainfo.PieceKey {
	return metainfo.PieceKey{InfoHash: fs.infoHash, Index: fs.p.Index()}
}

func (fs *filePieceImpl) Completion() storage.Completion {
	fs.ioMu.RLock()
	defer fs.ioMu.RUnlock()
	if fs.frozen {
		return storage.Completion{Ok: true}
	}
	c, err := fs.completion.Get(fs.pieceKey())
	if err != nil {
		log.Printf("error getting piece completion: %s", err)
		c.Ok = false
		return c
	}

	verified := true
	if c.Complete {
		// If it's allegedly complete, check that its constituent files have the necessary length.
		for _, fi := range extentCompleteRequiredLengths(fs.p.Info, fs.p.Offset(), fs.p.Length()) {
			s, err := outputfile.Stat(fs.files[fi.fileIndex].path)
			if err != nil || s.Size() < fi.length {
				verified = false
				break
			}
		}
	}

	if !verified {
		// The completion was wrong, fix it.
		c.Complete = false
		fs.completion.Set(fs.pieceKey(), false)
	}

	return c
}

func (fs *filePieceImpl) MarkComplete() error {
	fs.ioMu.RLock()
	defer fs.ioMu.RUnlock()
	if fs.frozen {
		return nil
	}
	return fs.completion.Set(fs.pieceKey(), true)
}

func (fs *filePieceImpl) MarkNotComplete() error {
	fs.ioMu.RLock()
	defer fs.ioMu.RUnlock()
	return fs.completion.Set(fs.pieceKey(), false)
}
