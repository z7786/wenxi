package http

import (
	"bytes"
	"encoding/xml"
	"io"
)

const tianyiBodyTailSize = 8 * 1024

// Tianyi can end an otherwise valid 206 stream with an XML storage error.
// Keep its last bytes private until the response ends so retries cannot count
// that error document as downloaded file data. Ordinary interruptions retain
// every valid byte, and complete responses are never altered.
type tianyiBodyReader struct {
	reader   io.Reader
	expected int64
	received int64
	pending  []byte
	buffer   [tianyiBodyTailSize]byte
	finished bool
	err      error
}

func newTianyiBodyReader(reader io.Reader, expected int64) *tianyiBodyReader {
	return &tianyiBodyReader{
		reader: reader, expected: expected,
		pending: make([]byte, 0, 2*tianyiBodyTailSize),
	}
}

func (r *tianyiBodyReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for !r.finished && len(r.pending) <= tianyiBodyTailSize {
		n, err := r.reader.Read(r.buffer[:])
		r.received += int64(n)
		r.pending = append(r.pending, r.buffer[:n]...)
		if err != nil {
			r.finished, r.err = true, err
			if r.received < r.expected {
				if start := tianyiErrorTail(r.pending); start >= 0 {
					r.pending = r.pending[:start]
					r.err = io.ErrUnexpectedEOF
				}
			}
		} else if n == 0 {
			return 0, nil
		}
	}
	available := len(r.pending)
	if !r.finished {
		available -= tianyiBodyTailSize
	}
	n := copy(p, r.pending[:available])
	r.pending = r.pending[:copy(r.pending, r.pending[n:])]
	if r.finished && len(r.pending) == 0 {
		return n, r.err
	}
	return n, nil
}

// Only the observed storage-error envelope at the end of an incomplete stream
// is recognized. Do not scan or reinterpret ordinary XML, HTML or file data.
func tianyiErrorTail(data []byte) int {
	start := bytes.LastIndex(data, []byte("<?xml"))
	if start < 0 {
		start = bytes.LastIndex(data, []byte("<Error>"))
	}
	if start < 0 {
		return -1
	}
	document := bytes.TrimSpace(data[start:])
	if !bytes.HasSuffix(document, []byte("</Error>")) {
		return -1
	}
	var envelope struct {
		XMLName xml.Name
		Code    string `xml:"Code"`
	}
	if err := xml.Unmarshal(document, &envelope); err != nil ||
		envelope.XMLName.Local != "Error" || envelope.Code != "GetObjectFailedInCoordinator" {
		return -1
	}
	return start
}
