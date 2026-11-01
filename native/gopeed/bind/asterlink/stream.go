package gopeed

// A local range server drives verified torrent readers. Playback has isolated
// storage, so seeking cannot change a download task's output or completion map.
import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/GopeedLab/gopeed/internal/btpolicy"
	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/storage"
	"golang.org/x/time/rate"
)

const streamCacheName = ".bt-stream-cache"
const streamMaxReadahead int64 = 32 * 1024 * 1024
const streamMaxReaders = 4

var streamMu sync.Mutex
var streams = map[string]*torrentStream{}

type torrentStream struct {
	id, dir, path, uri, name, etag string
	client                         *torrent.Client
	torrent                        *torrent.Torrent
	file                           *torrent.File
	storage                        storage.ClientImplCloser
	server                         *http.Server
	cancel                         context.CancelFunc
	ctx                            context.Context
	requests                       sync.WaitGroup
	requestMu                      sync.Mutex
	activeReaders                  map[uint64]context.CancelFunc
	requestSequence                uint64
	probeCancel                    context.CancelFunc
	probesStarted                  bool
	pieceLength                    int64
	readahead                      atomic.Int64
	readWaitMillis                 atomic.Int64
	firstByteMillis                atomic.Int64
	interrupts                     int
	closed                         bool
	startedAt                      time.Time
	sampleAt                       time.Time
	sampleBytes                    int64
}

func resetStreamCache(root string) error {
	dir := filepath.Join(root, streamCacheName)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	return clearStreamDirectory(dir, dir)
}

func clearStreamDirectory(dir, cacheRoot string) error {
	// Both permitted targets are absolute, app-owned paths: the cache root or
	// one MkdirTemp child. Never reuse the download task deletion path here.
	dir, cacheRoot = filepath.Clean(dir), filepath.Clean(cacheRoot)
	if cacheRoot != filepath.Join(payloadRoot, streamCacheName) || !filepath.IsAbs(cacheRoot) || (dir != cacheRoot &&
		(filepath.Dir(dir) != cacheRoot || !strings.HasPrefix(filepath.Base(dir), "play-"))) {
		return errors.New("invalid stream cache directory")
	}
	for _, path := range []string{cacheRoot, dir} {
		info, err := os.Lstat(path)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("invalid stream cache directory")
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err = os.RemoveAll(filepath.Join(dir, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func StartTorrentStream(value string) (string, error) {
	var input request
	if json.Unmarshal([]byte(value), &input) != nil || !safeID.MatchString(input.ID) {
		return "", errors.New("无效的 BT 播放请求")
	}
	mi, info, err := parseTorrent(input.TorrentData)
	if err != nil {
		return "", err
	}
	if input.TorrentIndex < 0 || input.TorrentIndex >= len(info.Files) || info.Files[input.TorrentIndex].Size <= 0 {
		return "", errors.New("此种子文件无法播放")
	}
	apiMu.Lock()
	defer apiMu.Unlock()
	if core == nil {
		return "", errors.New("下载组件尚未初始化")
	}
	if input.BTUploadLimit != nil {
		btpolicy.SetUploadLimit(*input.BTUploadLimit)
	}
	streamMu.Lock()
	defer streamMu.Unlock()
	if len(streams) != 0 {
		return "", errors.New("请先关闭当前 BT 播放")
	}
	dir, err := os.MkdirTemp(filepath.Join(payloadRoot, streamCacheName), "play-")
	if err != nil {
		return "", errors.New("无法创建 BT 播放缓存")
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &torrentStream{
		id: input.ID, dir: dir, ctx: ctx, cancel: cancel,
		sampleAt: time.Now(), startedAt: time.Now(), pieceLength: info.PieceLength,
		activeReaders: make(map[uint64]context.CancelFunc),
	}
	ready := false
	defer func() {
		if !ready {
			s.close()
		}
	}()
	cfg := torrent.NewDefaultClientConfig()
	btpolicy.Configure(cfg)
	cfg.DataDir, cfg.ListenPort = dir, 0
	if err = prepareStreamFile(filepath.Join(dir, filepath.FromSlash(info.Files[input.TorrentIndex].Path))); err != nil {
		return "", errors.New("无法创建 BT 播放缓存文件")
	}
	s.storage = &streamStorage{base: storage.NewFileWithCompletion(dir, storage.NewMapPieceCompletion())}
	cfg.DefaultStorage = s.storage
	if input.SpeedLimit > 0 {
		cfg.DownloadRateLimiter = rate.NewLimiter(rate.Limit(input.SpeedLimit), 512*1024)
	}
	s.client, err = torrent.NewClient(cfg)
	if err != nil {
		return "", errors.New("BT 播放连接初始化失败")
	}
	s.torrent, err = s.client.AddTorrent(mi)
	if err != nil {
		return "", errors.New("无法读取 BT 播放信息")
	}
	btpolicy.Restore(s.torrent)
	btpolicy.AddPublicTrackers(s.torrent)
	s.file = s.torrent.Files()[input.TorrentIndex]
	s.name = filepath.Base(info.Files[input.TorrentIndex].Path)
	s.etag = `"` + info.Hash + "-" + strconv.Itoa(input.TorrentIndex) + `"`
	var token [24]byte
	if _, err = rand.Read(token[:]); err != nil {
		return "", errors.New("无法初始化本地播放地址")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return "", errors.New("无法启动本地播放连接")
	}
	s.path = "/" + hex.EncodeToString(token[:]) + "/" + s.name
	s.uri = "http://" + listener.Addr().String() + "/" + hex.EncodeToString(token[:]) + "/" + url.PathEscape(s.name)
	s.server = &http.Server{
		Handler: http.HandlerFunc(s.serve), ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout: 15 * time.Second, MaxHeaderBytes: 8 * 1024,
	}
	streams[input.ID] = s
	go s.server.Serve(listener)
	ready = true
	result, err := json.Marshal(map[string]any{
		"id": input.ID, "url": s.uri, "size": s.file.Length(),
		"peerLimit": btpolicy.PeerLimit, "readaheadBytes": streamMaxReadahead,
	})
	return string(result), err
}

type streamReader struct {
	torrent.Reader
	ctx    context.Context
	stream *torrentStream
}

func (r streamReader) Read(buf []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	r.stream.startContainerProbes()
	// Each read can wait for missing pieces, but cancellation/seek is immediate.
	ctx, cancel := context.WithTimeout(r.ctx, 45*time.Second)
	defer cancel()
	start := time.Now()
	n, err := r.Reader.ReadContext(ctx, buf)
	r.stream.readWaitMillis.Add(time.Since(start).Milliseconds())
	if n > 0 {
		r.stream.firstByteMillis.CompareAndSwap(0, max(1, time.Since(r.stream.startedAt).Milliseconds()))
	}
	return n, err
}

func (s *torrentStream) serve(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != s.path {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if strings.Contains(r.Header.Get("Range"), ",") {
		http.Error(w, "one range per request", http.StatusRequestedRangeNotSatisfiable)
		return
	}
	ctx, cancel := context.WithCancel(s.ctx)
	stop := context.AfterFunc(r.Context(), cancel)
	defer stop()
	defer cancel()
	s.requestMu.Lock()
	if s.closed {
		s.requestMu.Unlock()
		http.Error(w, "playback closed", http.StatusGone)
		return
	}
	var requestID uint64
	if r.Method == http.MethodGet {
		// Demuxers can read the header, index and media concurrently. Only an
		// explicit seek/disposal interrupts them; another GET is not a seek.
		if len(s.activeReaders) >= streamMaxReaders {
			s.requestMu.Unlock()
			http.Error(w, "too many media readers", http.StatusTooManyRequests)
			return
		}
		s.requestSequence++
		requestID = s.requestSequence
		s.activeReaders[requestID] = cancel
	}
	s.requests.Add(1)
	s.requestMu.Unlock()
	defer s.requests.Done()
	if requestID != 0 {
		defer func() {
			s.requestMu.Lock()
			delete(s.activeReaders, requestID)
			s.requestMu.Unlock()
		}()
	}
	reader := s.file.NewReader()
	defer reader.Close()
	reader.SetReadaheadFunc(s.streamReadahead(streamRequestBytes(r.Header.Get("Range"), s.file.Length())))
	contentType := mime.TypeByExtension(filepath.Ext(s.name))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("ETag", s.etag)
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// Never use SetResponsive: data is exposed only after piece hash validation.
	http.ServeContent(w, r.WithContext(ctx), s.name, time.Time{}, streamReader{reader, ctx, s})
}

func TorrentStreamStatus(id string) (string, error) {
	streamMu.Lock()
	defer streamMu.Unlock()
	s := streams[id]
	if s == nil {
		return "", errors.New("BT 播放已关闭")
	}
	stats := s.torrent.Stats()
	now := time.Now()
	bytes := stats.BytesReadData.Int64()
	var speed int64
	if elapsed := now.Sub(s.sampleAt).Seconds(); elapsed > 0 {
		speed = max(0, int64(float64(bytes-s.sampleBytes)/elapsed))
	}
	s.sampleAt, s.sampleBytes = now, bytes
	s.requestMu.Lock()
	active, ranges, interrupts, probing := len(s.activeReaders), s.requestSequence, s.interrupts, s.probesStarted
	s.requestMu.Unlock()
	value, err := json.Marshal(map[string]any{
		"activePeers": stats.ActivePeers, "seeders": stats.ConnectedSeeders,
		"pendingPeers": stats.PendingPeers, "peerLimit": btpolicy.PeerLimit,
		"downloaded": s.file.BytesCompleted(), "total": s.file.Length(), "speed": speed,
		"activeRequests": active, "rangeRequests": ranges, "interrupts": interrupts,
		"pieceLength": s.pieceLength, "readaheadBytes": max(2*1024*1024, s.readahead.Load()),
		"containerPrefetch": probing, "readWaitMillis": s.readWaitMillis.Load(),
		"firstByteMillis": s.firstByteMillis.Load(),
	})
	return string(value), err
}

func StopTorrentStream(id string) {
	streamMu.Lock()
	defer streamMu.Unlock()
	if s := streams[id]; s != nil {
		delete(streams, id)
		s.close()
	}
}

// Interrupt a blocked media read before disposing/rebuilding the player. Keep
// verified pieces and the peer session for a possible software-decoder retry.
func InterruptTorrentStream(id string) {
	streamMu.Lock()
	defer streamMu.Unlock()
	if s := streams[id]; s != nil {
		s.requestMu.Lock()
		for _, cancel := range s.activeReaders {
			cancel()
		}
		// Release the reader slots immediately; cancelled handlers still join
		// the shutdown wait group and remove only their own sequence IDs.
		s.activeReaders = make(map[uint64]context.CancelFunc)
		if s.probeCancel != nil {
			s.probeCancel()
		}
		s.interrupts++
		s.requestMu.Unlock()
	}
}

func (s *torrentStream) close() {
	s.requestMu.Lock()
	s.closed = true
	s.cancel()
	s.requestMu.Unlock()
	if s.server != nil {
		s.server.Close()
	}
	s.requests.Wait()
	btpolicy.Remember(s.torrent)
	btpolicy.RememberDHT(s.client)
	if s.client != nil {
		s.client.Close()
	}
	if s.storage != nil {
		s.storage.Close()
	}
	// s.dir comes only from MkdirTemp inside the app-owned stream cache.
	if s.dir != "" {
		if clearStreamDirectory(s.dir, filepath.Dir(s.dir)) == nil {
			os.Remove(s.dir)
		}
	}
}

func closeTorrentStreams() {
	streamMu.Lock()
	defer streamMu.Unlock()
	for id, s := range streams {
		delete(streams, id)
		s.close()
	}
}

var _ io.ReadSeeker = streamReader{}
