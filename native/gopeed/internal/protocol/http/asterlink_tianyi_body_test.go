package http

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

const tianyiStorageError = `<?xml version="1.0" encoding="UTF-8"?><Error><Code>GetObjectFailedInCoordinator</Code><Message>Coordinator get object cause any exceptions.</Message><RequestId>fixture</RequestId></Error>`

func TestTianyiBodyRemovesStorageErrorFromInterruptedStream(t *testing.T) {
	for _, validSize := range []int{0, 17, 8191, 8192, 8193, 3*8192 + 27} {
		t.Run(fmt.Sprint(validSize), func(t *testing.T) {
			valid := bytes.Repeat([]byte{0x5a}, validSize)
			body := append(bytes.Clone(valid), tianyiStorageError...)
			reader := newTianyiBodyReader(bytes.NewReader(body), int64(len(body)+8192))
			got, err := io.ReadAll(reader)
			if !errors.Is(err, io.ErrUnexpectedEOF) || !bytes.Equal(got, valid) {
				t.Fatalf("storage error counted as file data: bytes=%d want=%d err=%v", len(got), len(valid), err)
			}
		})
	}
}

func TestTianyiBodyPreservesCompleteFilesAndOrdinaryInterruptions(t *testing.T) {
	for _, body := range [][]byte{
		{},
		bytes.Repeat([]byte("ordinary-data"), 4096),
		[]byte(tianyiStorageError),
		[]byte(`<?xml version="1.0"?><document><Code>GetObjectFailedInCoordinator</Code></document>`),
		[]byte(`<?xml version="1.0"?><Error><Code>SomeOtherCode</Code></Error>`),
		[]byte(tianyiStorageError + "more valid file data"),
	} {
		for _, extra := range []int64{0, 8192} {
			if extra > 0 && bytes.Equal(body, []byte(tianyiStorageError)) {
				continue
			}
			reader := newTianyiBodyReader(bytes.NewReader(body), int64(len(body))+extra)
			got, err := io.ReadAll(reader)
			if err != nil || !bytes.Equal(got, body) {
				t.Fatalf("valid file bytes changed: length=%d extra=%d got=%d err=%v", len(body), extra, len(got), err)
			}
		}
	}
}

func TestTianyiRangeRetriesAfterAppendedStorageError(t *testing.T) {
	data := make([]byte, 2*1024*1024)
	for i := range data {
		data[i] = byte((i*17 + i/113) % 251)
	}
	var injected atomic.Bool
	var resumed atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if first == 0 && last == 0 {
			xunleiResponse(w, first, last, len(data))
			_, _ = w.Write(data[:1])
			return
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, len(data)))
		w.Header().Set("Content-Length", fmt.Sprint(last-first+1))
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusPartialContent)
		// Flush first: the CDN keeps a correct 206/Content-Range header even
		// though its stream terminates with an XML error document.
		w.(http.Flusher).Flush()
		if first == 0 && injected.CompareAndSwap(false, true) {
			_, _ = w.Write(data[:256*1024])
			_, _ = io.WriteString(w, tianyiStorageError)
			return
		}
		if first == 256*1024 {
			resumed.Store(true)
		}
		_, _ = w.Write(data[first : last+1])
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	retries := 2
	if err := f.Create(&base.Options{
		Name: "tianyi-interruption.bin", Path: t.TempDir(),
		Extra: &fhttp.OptsExtra{Connections: 2, ConnectionProfile: "tianyi", RetryLimit: &retries},
	}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	verifyXunleiDownload(t, f, data)
	if !injected.Load() || !resumed.Load() {
		t.Fatal("did not retry from the valid byte boundary")
	}
}

func TestTianyiRangeExhaustionDoesNotPublishErrorBytes(t *testing.T) {
	data := bytes.Repeat([]byte{0x5a}, 64*1024)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		first, last, ok := xunleiRange(t, r, len(data))
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", first, last, len(data)))
		w.WriteHeader(http.StatusPartialContent)
		w.(http.Flusher).Flush()
		if first == 0 && last == 0 {
			_, _ = w.Write(data[:1])
			return
		}
		_, _ = w.Write(data[:4096])
		_, _ = io.WriteString(w, tianyiStorageError)
	}))
	defer server.Close()
	f := buildFetcher()
	defer f.Close()
	if err := f.Resolve(&base.Request{URL: server.URL}); err != nil {
		t.Fatal(err)
	}
	retries := 0
	if err := f.Create(&base.Options{Name: "failed.bin", Path: t.TempDir(),
		Extra: &fhttp.OptsExtra{Connections: 1, ConnectionProfile: "tianyi", RetryLimit: &retries}}); err != nil {
		t.Fatal(err)
	}
	if err := f.Start(); err != nil {
		t.Fatal(err)
	}
	if err := f.Wait(); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("expected retryable interruption, got %v", err)
	}
	if got := f.Progress(); len(got) != 1 || got[0] != 4096 {
		t.Fatalf("invalid progress after interruption: %v", got)
	}
	file, err := os.ReadFile(f.Meta().SingleFilepath())
	if err != nil || bytes.Contains(file, []byte("<?xml")) || !bytes.Equal(file[:4096], data[:4096]) {
		t.Fatal("error document was written to the resumable file")
	}
}
