// AsterLink Android integration modifications, 2026-09-12. See native/README.md.
// Based on Gopeed v1.8.1, licensed under GPL-3.0.
package http

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/GopeedLab/gopeed/internal/controller"
	"github.com/GopeedLab/gopeed/internal/fetcher"
	"github.com/GopeedLab/gopeed/internal/outputfile"
	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
	"github.com/GopeedLab/gopeed/pkg/util"
	"github.com/xiaoqidun/setft"
	"golang.org/x/sync/errgroup"
	"golang.org/x/time/rate"
)

const (
	connectTimeout = 15 * time.Second
	readTimeout    = 15 * time.Second
	helpMinSize    = 1 * 1024 * 1024
)

type RequestError struct {
	Code       int
	Msg        string
	RetryAfter time.Time
}

func NewRequestError(code int, msg string) *RequestError {
	return &RequestError{Code: code, Msg: msg}
}

func (re *RequestError) Error() string {
	return fmt.Sprintf("http request fail,code:%d", re.Code)
}

type chunk struct {
	Begin      int64
	End        int64
	Downloaded int64
}

type connection struct {
	mu         sync.RWMutex
	Chunk      *chunk
	Downloaded int64
	Completed  bool

	failed     bool
	retryTimes int
	terminated bool
	tail       tailSample
}

// get remain to download bytes
func (c *chunk) remain() int64 {
	return c.End - c.Begin + 1 - c.Downloaded
}

func newChunk(begin int64, end int64) *chunk {
	return &chunk{
		Begin: begin,
		End:   end,
	}
}

type Fetcher struct {
	ctl    *controller.Controller
	config *config
	doneCh chan error

	meta         *fetcher.FetcherMeta
	connections  []*connection
	helpLock     sync.Mutex
	tailChanged  chan struct{}
	redirectURL  string
	redirectLock sync.Mutex

	file              *os.File
	cancel            context.CancelFunc
	eg                *errgroup.Group
	rate              *rate.Limiter
	stopped           chan struct{}
	closed            chan struct{}
	closeOnce         sync.Once
	activeConnections atomic.Int32
	totalConnections  atomic.Int32
	readable          readableBytes
	aliyun            atomic.Pointer[aliyunTask]
}

func (f *Fetcher) Setup(ctl *controller.Controller) {
	f.ctl = ctl
	f.doneCh = make(chan error, 1)
	f.closed = make(chan struct{})
	if f.meta == nil {
		f.meta = &fetcher.FetcherMeta{}
	}
	f.ctl.GetConfig(&f.config)
	return
}

func (f *Fetcher) Resolve(req *base.Request) error {
	return f.ResolveContext(context.Background(), req)
}

func (f *Fetcher) ResolveContext(ctx context.Context, req *base.Request) error {
	if err := base.ParseReqExtra[fhttp.ReqExtra](req); err != nil {
		return err
	}
	f.meta.Req = req
	httpReq, err := f.buildRequest(ctx, req)
	if err != nil {
		return err
	}
	client := f.buildClient()
	client.Timeout = 30 * time.Second
	if err := waitForHost(ctx, httpReq.URL.Host); err != nil {
		return err
	}
	// send Range request to check whether the server supports breakpoint continuation
	// just test one byte, Range: bytes=0-0
	httpReq.Header.Set(base.HttpHeaderRange, fmt.Sprintf(base.HttpHeaderRangeFormat, 0, 0))
	httpResp, err := client.Do(httpReq)
	if err != nil {
		return err
	}
	// close response body immediately
	httpResp.Body.Close()
	// Some Guangya CDNs return HTTP 200 with a one-byte body for 0-0,
	// omitting the full object's size and range support. Retry with 0-1;
	// a genuine one-byte file is still valid if the server returns 200 again.
	if httpResp.StatusCode == http.StatusOK && httpResp.ContentLength == 1 && httpResp.Header.Get(base.HttpHeaderContentRange) == "" {
		httpReq, err = f.buildRequest(ctx, req)
		if err != nil {
			return err
		}
		httpReq.Header.Set(base.HttpHeaderRange, fmt.Sprintf(base.HttpHeaderRangeFormat, 0, 1))
		httpResp, err = client.Do(httpReq)
		if err != nil {
			return err
		}
		httpResp.Body.Close()
	}
	res := &base.Resource{
		Range: false,
		Files: []*base.FileInfo{},
	}

	if base.HttpCodePartialContent == httpResp.StatusCode || (base.HttpCodeOK == httpResp.StatusCode && httpResp.Header.Get(base.HttpHeaderAcceptRanges) == base.HttpHeaderBytes && strings.HasPrefix(httpResp.Header.Get(base.HttpHeaderContentRange), base.HttpHeaderBytes)) {
		// response 206 status code, support breakpoint continuation
		res.Range = true
		// parse content length from Content-Range header, eg: bytes 0-1000/1001 or bytes 0-0/*
		contentTotal := path.Base(httpResp.Header.Get(base.HttpHeaderContentRange))
		if contentTotal != "" && contentTotal != "*" {
			parse, err := strconv.ParseInt(contentTotal, 10, 64)
			if err != nil {
				return err
			}
			res.Size = parse
		}
	} else if base.HttpCodeOK == httpResp.StatusCode {
		// response 200 status code, not support breakpoint continuation, get file size by Content-Length header
		// if not found, maybe chunked encoding
		contentLength := httpResp.Header.Get(base.HttpHeaderContentLength)
		if contentLength != "" {
			parse, err := strconv.ParseInt(contentLength, 10, 64)
			if err != nil {
				return err
			}
			res.Size = parse
		}
	} else if httpResp.StatusCode == http.StatusRequestedRangeNotSatisfiable && httpResp.Header.Get(base.HttpHeaderContentRange) == "bytes */0" {
		// An empty file has no byte 0, so the capability probe legitimately returns 416.
		res.Size = 0
	} else {
		err := responseError(httpResp)
		if err.Code == 429 || err.Code == 503 {
			coolHost(httpReq.URL.Host, err.RetryAfter)
		}
		return err
	}
	if res.Size <= 0 {
		// A wildcard total cannot be split into finite ranges. Use a complete stream.
		res.Range = false
	}
	// Parse last modified time
	var lastModifiedTime *time.Time
	lastModified := httpResp.Header.Get(base.HttpHeaderLastModified)
	if lastModified != "" {
		// ignore parse error
		t, _ := time.Parse(time.RFC1123, lastModified)
		lastModifiedTime = &t
	}
	file := &base.FileInfo{
		Size:  res.Size,
		Ctime: lastModifiedTime,
	}
	contentDisposition := httpResp.Header.Get(base.HttpHeaderContentDisposition)
	if contentDisposition != "" {
		_, params, _ := mime.ParseMediaType(contentDisposition)
		filename := params["filename"]
		if filename != "" {
			// Check if the filename is MIME encoded-word
			if strings.HasPrefix(filename, "=?") {
				decoder := new(mime.WordDecoder)
				filename = strings.Replace(filename, "UTF8", "UTF-8", 1)
				file.Name, _ = decoder.Decode(filename)
			} else {
				file.Name = util.TryUrlQueryUnescape(filename)
			}
		} else {
			substr := "attachment; filename="
			index := strings.Index(contentDisposition, substr)
			if index != -1 {
				file.Name = util.TryUrlQueryUnescape(contentDisposition[index+len(substr):])
			}
		}
	}
	// get file filePath by URL
	if file.Name == "" {
		file.Name = path.Base(httpReq.URL.Path)
		// Url decode
		if file.Name != "" {
			file.Name, _ = url.QueryUnescape(file.Name)
		}
	}
	// unknown file filePath
	if file.Name == "" || file.Name == "/" || file.Name == "." {
		file.Name = httpReq.URL.Hostname()
	}
	res.Files = append(res.Files, file)
	f.meta.Res = res
	return nil
}

func (f *Fetcher) Create(opts *base.Options) error {
	f.meta.Opts = opts

	if err := base.ParseOptsExtra[fhttp.OptsExtra](f.meta.Opts); err != nil {
		return err
	}
	if opts.Extra == nil {
		opts.Extra = &fhttp.OptsExtra{}
	}
	extra := opts.Extra.(*fhttp.OptsExtra)
	if extra.Connections <= 0 {
		extra.Connections = f.config.Connections
		// Avoid zero connections configuration
		if extra.Connections <= 0 {
			extra.Connections = 1
		}
	}
	return nil
}

func (f *Fetcher) Start() (err error) {
	name := f.meta.SingleFilepath()
	_, direct := outputfile.Path(name)
	if !direct && f.meta.Req.Labels[outputfile.KeyLabel] != "" {
		return errors.New("direct output lease unavailable")
	}
	if direct {
		if f.connections == nil {
			if err = outputfile.Reset(name, f.meta.Res.Size); err != nil {
				return err
			}
		}
		f.file, err = outputfile.OpenFile(name, os.O_RDWR, 0)
	} else {
		// if file not exist, create it, else open it
		_, err = os.Stat(name)
		if err != nil {
			if os.IsNotExist(err) {
				f.file, err = f.ctl.Touch(name, f.meta.Res.Size)
			} else {
				return
			}
		} else {
			f.file, err = os.OpenFile(name, os.O_RDWR, os.ModeAppend)
		}
	}
	if err != nil {
		return err
	}

	// Avoid request extra modified by extension
	if err = base.ParseReqExtra[fhttp.ReqExtra](f.meta.Req); err != nil {
		return err
	}

	if f.connections == nil {
		f.connections = f.splitConnection()
	}
	f.expandPublicConnections()
	f.initializeReadable()
	f.totalConnections.Store(int32(len(f.connections)))
	if limit := connectionLimit(f.meta.Opts.Extra.(*fhttp.OptsExtra)); limit > 0 {
		f.totalConnections.Store(int32(min(len(f.connections), limit)))
	}
	if limit := f.meta.Opts.Extra.(*fhttp.OptsExtra).SpeedLimit; limit > 0 {
		f.rate = rate.NewLimiter(rate.Limit(limit), 8192)
	} else {
		f.rate = nil
	}
	f.redirectURL = ""
	if extra := f.meta.Opts.Extra.(*fhttp.OptsExtra); extra.ConnectionProfile == "aliyun" {
		f.PrepareAliyunTransfer(extra.AliyunGroup, extra.Connections)
	} else {
		f.aliyun.Store(nil)
	}
	f.fetch()
	return
}

func (f *Fetcher) Pause() (err error) {
	if f.cancel != nil {
		f.cancel()
		// Wait for both workers and their completion/close handler before reuse.
		<-f.stopped
		f.file.Close()
		f.cancel = nil
	}
	return
}

func (f *Fetcher) Close() (err error) {
	if err = f.Pause(); err != nil {
		return
	}
	f.closeOnce.Do(func() { close(f.closed) })
	return
}

func (f *Fetcher) Meta() *fetcher.FetcherMeta {
	return f.meta
}

func (f *Fetcher) Stats() any {
	statsConnections := make([]*fhttp.StatsConnection, 0)
	for _, connection := range f.connections {
		connection.mu.RLock()
		statsConnections = append(statsConnections, &fhttp.StatsConnection{
			Downloaded: connection.Downloaded,
			Completed:  connection.Completed,
			Failed:     connection.failed,
			RetryTimes: connection.retryTimes,
		})
		connection.mu.RUnlock()
	}
	return &fhttp.Stats{
		Connections: statsConnections,
	}
}

func (f *Fetcher) Progress() fetcher.Progress {
	p := make(fetcher.Progress, 0)
	if len(f.connections) > 0 {
		total := int64(0)
		for _, connection := range f.connections {
			connection.mu.RLock()
			total += connection.Downloaded
			connection.mu.RUnlock()
		}
		p = append(p, total)
	}
	return p
}

func (f *Fetcher) Wait() (err error) {
	select {
	case err = <-f.doneCh:
		return err
	case <-f.closed:
		return context.Canceled
	}
}

func (f *Fetcher) fetch() {
	var ctx context.Context
	ctx, f.cancel = context.WithCancel(context.Background())
	f.eg, _ = errgroup.WithContext(ctx)
	f.stopped = make(chan struct{})
	group, file, stopped := f.eg, f.file, f.stopped
	f.helpLock.Lock()
	f.tailChanged = make(chan struct{})
	f.helpLock.Unlock()
	for _, connection := range f.connections {
		connection.mu.Lock()
		connection.terminated = false
		connection.tail = tailSample{}
		connection.mu.Unlock()
	}
	connectionErrs := make([]error, len(f.connections))
	var connectionSlots chan struct{}
	if limit := connectionLimit(f.meta.Opts.Extra.(*fhttp.OptsExtra)); limit > 0 {
		// Old checkpoints can contain multiple partially downloaded ranges.
		// Preserve their bytes while respecting the current route's limit.
		connectionSlots = make(chan struct{}, limit)
	}
	for i := 0; i < len(f.connections); i++ {
		i := i
		f.eg.Go(func() error {
			err := f.run(i, ctx, connectionSlots)
			// if canceled, fail fast
			if errors.Is(err, context.Canceled) {
				return err
			}
			connectionErrs[i] = err
			return nil
		})
	}

	go func() {
		defer close(stopped)
		err := group.Wait()
		// error returned only if canceled, just return
		if err != nil {
			return
		}
		// check all fetch results, if any error, return
		for _, chunkErr := range connectionErrs {
			if chunkErr != nil {
				err = chunkErr
				break
			}
		}

		file.Close()
		// Update file last modified time
		if f.config.UseServerCtime && f.meta.Res.Files[0].Ctime != nil {
			setft.SetFileTime(file.Name(), time.Now(), *f.meta.Res.Files[0].Ctime, *f.meta.Res.Files[0].Ctime)
		}
		f.doneCh <- err
	}()
}

func (f *Fetcher) run(index int, ctx context.Context, connectionSlots chan struct{}) (err error) {
	connection := f.connections[index]
	connection.mu.Lock()
	connection.failed = false
	connection.retryTimes = 0
	connection.Completed = false
	connection.mu.Unlock()
	defer func() {
		connection.mu.Lock()
		connection.terminated = true
		connection.mu.Unlock()
		f.notifyTailChanged()
	}()
	// These providers return signed original-file URLs. Slow response headers
	// on one request must not hold every other range in a redirect lookup queue.
	profile := f.meta.Opts.Extra.(*fhttp.OptsExtra).ConnectionProfile
	cacheRedirect := profile != "aliyun" && profile != "xunlei" && f.sourceNetworkPolicy() == nil
	var (
		client = f.buildClient()
		buf    = make([]byte, 8192)
	)
	defer client.CloseIdleConnections()

	downloadChunk := func() (err error) {
		attempts := 0
		retries := fhttp.DefaultRetryLimit
		if configured := f.meta.Opts.Extra.(*fhttp.OptsExtra).RetryLimit; configured != nil {
			retries = max(0, min(fhttp.MaxRetryLimit, *configured))
		}
		// A task's retry setting applies even if every connection is failing.
		for {
			// if chunk is completed, return
			if f.meta.Res.Range && connection.remaining() <= 0 {
				return nil
			}
			err = func() (requestErr error) {
				// Only a live request owns a slot. Idle helpers must not keep
				// queued checkpoint ranges from obtaining their own request.
				if connectionSlots != nil {
					select {
					case connectionSlots <- struct{}{}:
						defer func() { <-connectionSlots }()
					case <-ctx.Done():
						return ctx.Err()
					}
				}
				host := ""
				if uri, parseErr := url.Parse(f.meta.Req.URL); parseErr == nil {
					host = uri.Host
				}
				if err := waitForHost(ctx, host); err != nil {
					return err
				}
				var lease *aliyunLease
				if policy := f.aliyun.Load(); profile == "aliyun" && policy != nil {
					lease, err = policy.acquire(ctx)
					if err != nil {
						return err
					}
					defer lease.release()
					defer func() { lease.failed(requestErr, retryDelay(attempts), time.Now()) }()
				}
				// Aliyun's account scheduler owns its limit across all CDN hosts.
				budgetProfile := profile
				if lease != nil {
					budgetProfile = ""
				}
				release, err := acquireProfileConnection(ctx, host, budgetProfile)
				if err != nil {
					return err
				}
				defer release()
				if err := waitForHost(ctx, host); err != nil {
					return err
				}
				var (
					httpReq *http.Request
					resp    *http.Response
					counted bool
				)
				requestRemaining := int64(-1)
				defer func() {
					if counted {
						f.activeConnections.Add(-1)
					}
				}()
				if cacheRedirect {
					f.redirectLock.Lock()
					if f.redirectURL != "" {
						f.redirectLock.Unlock()
					}
				}
				err = func() (err error) {
					defer func() {
						if cacheRedirect && f.redirectURL == "" {
							if err == nil {
								f.redirectURL = resp.Request.URL.String()
							}
							f.redirectLock.Unlock()
						}
					}()

					httpReq, err = f.buildRequest(ctx, f.meta.Req)
					if err != nil {
						return
					}
					if f.meta.Res.Range {
						connection.mu.RLock()
						chunk := connection.Chunk
						first, last := chunk.Begin+chunk.Downloaded, chunk.End
						if profile == "baidu_preview" && last-first >= baiduPreviewRequestSize {
							last = first + baiduPreviewRequestSize - 1
						}
						if profile == "baidu_direct" && last-first >= minRangeSize {
							last = first + minRangeSize - 1
						}
						if profile == "aliyun" {
							last = aliyunRangeEnd(first, last)
						}
						requestRemaining = last - first + 1
						httpReq.Header.Set(base.HttpHeaderRange,
							fmt.Sprintf(base.HttpHeaderRangeFormat, first, last))
						connection.mu.RUnlock()
					} else {
						connection.mu.Lock()
						connection.Chunk.Downloaded = 0
						connection.Downloaded = 0
						connection.mu.Unlock()
						if err = f.file.Truncate(0); err != nil {
							return err
						}
					}
					// Count only requests that have left the slot/cooldown/redirect
					// queues, through connection setup, headers and body transfer.
					if lease != nil {
						lease.begin()
					}
					f.activeConnections.Add(1)
					counted = true
					connection.mu.Lock()
					connection.tail.start(time.Now())
					connection.mu.Unlock()
					resp, err = client.Do(httpReq)
					if err != nil {
						return
					}
					return
				}()
				if err != nil {
					return err
				}

				defer resp.Body.Close()
				if resp.StatusCode != base.HttpCodeOK && resp.StatusCode != base.HttpCodePartialContent {
					failure := responseError(resp)
					if profile != "aliyun" && (failure.Code == 429 || failure.Code == 503) {
						if profile == "xunlei" {
							limitXunleiHost(host)
						}
						if profile == "guangya" {
							guangyaHosts.limit(host)
						}
						deadline := time.Now().Add(retryDelay(attempts))
						if failure.RetryAfter.After(deadline) {
							deadline = failure.RetryAfter
						}
						coolHost(host, deadline)
					}
					return failure
				}
				if err := validateRangeResponse(httpReq, resp, f.meta.Res.Size); err != nil {
					return err
				}
				connection.setRetryState(false, attempts)
				reader := NewTimeoutReader(resp.Body, readTimeout)
				for {
					n, err := reader.Read(buf)
					if n > 0 {
						if requestRemaining >= 0 {
							if int64(n) > requestRemaining {
								return NewRequestError(412, "remote range body exceeded requested size")
							}
							requestRemaining -= int64(n)
						}
						if f.rate != nil {
							if err := f.rate.WaitN(ctx, n); err != nil {
								return err
							}
						}
						finished, err := f.writeChunk(connection, buf[:n])
						if err != nil {
							return err
						}
						if lease != nil {
							lease.progress(int64(n), time.Now())
						}

						if finished {
							return nil
						}
					}
					if err != nil {
						if err == io.EOF {
							connection.mu.RLock()
							incomplete := (f.meta.Res.Range && requestRemaining > 0) || (!f.meta.Res.Range && f.meta.Res.Size > 0 && connection.Chunk.Downloaded != f.meta.Res.Size)
							connection.mu.RUnlock()
							if incomplete {
								return io.ErrUnexpectedEOF
							}
							return nil
						}
						return err
					}
				}
			}()
			if err != nil {
				// If canceled, do not retry
				if errors.Is(err, context.Canceled) || errors.Is(err, fhttp.ErrNetworkPolicy) {
					return
				}
				var status *RequestError
				if errors.As(err, &status) && (status.Code == 401 || status.Code == 403 || status.Code == 410 || status.Code == 412) {
					return err
				}
				if attempts >= retries {
					return err
				}
				delay := retryDelay(attempts)
				attempts++
				// Space retries out so a transient 503 or interrupted transfer does
				// not immediately hit the same overloaded endpoint again.
				connection.setRetryState(true, attempts)
				if policy := f.aliyun.Load(); profile == "aliyun" && policy != nil {
					policy.retryWait(time.Now().Add(delay + time.Duration(index%17)*17*time.Millisecond))
				}
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(delay + time.Duration(index%17)*17*time.Millisecond):
				}
				continue
			}
			// A completed request starts a fresh retry window.  This matters
			// when the same connection later receives another transient 503 or
			// loses its stream: past failures must not consume the new window.
			attempts = 0
			connection.setRetryState(false, 0)
			if f.meta.Res.Range && connection.remaining() > 0 {
				// A complete preview window is progress, not an interrupted chunk.
				// Continue from the saved byte offset without adding a connection.
				continue
			}
			break
		}
		return
	}

	for {
		if err = downloadChunk(); err != nil {
			return
		}

		// check this connection is completed
		connection.mu.Lock()
		connection.Completed = true
		connection.mu.Unlock()
		f.notifyTailChanged()
		if !f.meta.Res.Range || fhttp.BaiduConnectionLimit(profile) > 0 {
			return nil
		}
		if helped, waitErr := f.waitForOtherConnection(ctx, connection); waitErr != nil {
			return waitErr
		} else if !helped {
			return
		}
	}
}

func (f *Fetcher) helpOtherConnection(helper *connection) (helped, pending bool, changed <-chan struct{}) {
	f.helpLock.Lock()
	defer f.helpLock.Unlock()

	minimum := int64(helpMinSize)
	extra := f.meta.Opts.Extra.(*fhttp.OptsExtra)
	if extra.ConnectionProfile == "xunlei" {
		// At 64 connections, a 100 MiB file starts with ~1.6 MiB per worker.
		// Help the smaller tail too, keeping each new half at least 256 KiB.
		minimum = 2 * minRangeSize
	}
	adaptive := extra.SpeedLimit <= 0
	for {
		pending = false
		var target *connection
		var maxRemain int64
		now := time.Now()
		for _, candidate := range f.connections {
			if candidate == helper {
				continue
			}
			candidate.mu.RLock()
			remain := candidate.Chunk.remain()
			available := !candidate.Completed && !candidate.terminated
			worthHelping := available && !candidate.failed &&
				(remain > minimum || adaptive && candidate.tail.slow(remain, now))
			pending = pending || adaptive && available && remain >= 2*tailMinRangeSize
			candidate.mu.RUnlock()
			if worthHelping && remain > maxRemain {
				target, maxRemain = candidate, remain
			}
		}
		if target == nil {
			return false, pending, f.tailChanged
		}
		target.mu.Lock()
		remain := target.Chunk.remain()
		if target.Completed || target.terminated || target.failed ||
			!(remain > minimum || adaptive && target.tail.slow(remain, time.Now())) {
			target.mu.Unlock()
			continue
		}
		// A worker cannot publish a write while its remaining range is split.
		// Otherwise two workers can claim the same bytes or save a torn checkpoint.
		helper.mu.Lock()
		helper.Chunk = newChunk(target.Chunk.End-remain/2+1, target.Chunk.End)
		target.Chunk.End = helper.Chunk.Begin - 1
		helper.Completed = false
		helper.tail = tailSample{}
		helper.mu.Unlock()
		target.mu.Unlock()
		return true, false, nil
	}
}

func (f *Fetcher) buildRequest(ctx context.Context, req *base.Request) (httpReq *http.Request, err error) {
	var reqUrl string
	if f.redirectURL != "" && f.sourceNetworkPolicy() == nil {
		reqUrl = f.redirectURL
	} else {
		reqUrl = req.URL
	}

	var (
		method string
		body   io.Reader
	)
	headers := http.Header{}
	if req.Extra == nil {
		method = http.MethodGet
	} else {
		extra := req.Extra.(*fhttp.ReqExtra)
		if extra.Method != "" {
			method = extra.Method
		} else {
			method = http.MethodGet
		}
		if len(extra.Header) > 0 {
			for k, v := range extra.Header {
				headers.Set(k, strings.TrimSpace(v))
			}
		}
		if extra.Body != "" {
			body = bytes.NewBufferString(extra.Body)
		}
	}
	if _, ok := headers[base.HttpHeaderUserAgent]; !ok {
		headers.Set(base.HttpHeaderUserAgent, strings.TrimSpace(f.config.UserAgent))
	}

	if ctx != nil {
		httpReq, err = http.NewRequestWithContext(ctx, method, reqUrl, body)
	} else {
		httpReq, err = http.NewRequest(method, reqUrl, body)
	}
	if err != nil {
		return
	}
	httpReq.Header = headers
	if policy := f.sourceNetworkPolicy(); policy != nil {
		if err = policy.CheckURL(httpReq.URL); err != nil {
			return nil, err
		}
	}
	// Override Host header
	if host := headers.Get(base.HttpHeaderHost); host != "" {
		httpReq.Host = host
	}
	return httpReq, nil
}

func (f *Fetcher) splitConnection() (connections []*connection) {
	if f.meta.Res.Range {
		extra := f.meta.Opts.Extra.(*fhttp.OptsExtra)
		optConnections := effectiveConnections(f.meta.Res.Size, extra.Connections, extra.ConnectionProfile)
		// 每个连接平均需要下载的分块大小
		chunkSize := f.meta.Res.Size / int64(optConnections)
		connections = make([]*connection, optConnections)
		for i := 0; i < optConnections; i++ {
			var (
				begin = chunkSize * int64(i)
				end   int64
			)
			if i == optConnections-1 {
				// 最后一个分块需要保证把文件下载完
				end = f.meta.Res.Size - 1
			} else {
				end = begin + chunkSize - 1
			}
			connections[i] = &connection{
				Chunk: newChunk(begin, end),
			}
		}
	} else {
		// 只支持单连接下载
		connections = make([]*connection, 1)
		connections[0] = &connection{
			Chunk: newChunk(0, 0),
		}
	}
	return
}

// ConnectionCounts reads transient counters without allocating per-range stats
// or taking a task lock from inside a progress event callback.
func (f *Fetcher) ConnectionCounts() (active, total int) {
	return int(f.activeConnections.Load()), int(f.totalConnections.Load())
}

func (f *Fetcher) buildClient() *http.Client {
	transport := &http.Transport{
		ResponseHeaderTimeout: readTimeout,
		TLSHandshakeTimeout:   connectTimeout,
		IdleConnTimeout:       30 * time.Second,
		DialContext: (&net.Dialer{
			Timeout: connectTimeout,
		}).DialContext,
		Proxy: f.ctl.GetProxy(f.meta.Req.Proxy),
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: f.meta.Req.SkipVerifyCert,
		},
	}
	// Cookie handle
	if policy := f.sourceNetworkPolicy(); policy != nil {
		return sourceClient(transport, policy)
	}
	jar, _ := cookiejar.New(nil)
	return &http.Client{
		Transport: transport,
		Jar:       jar,
	}
}

func decodeMangledString(mangled string) string {
	rawBytes := make([]byte, 0, len(mangled)*3)
	for _, r := range mangled {
		rawBytes = append(rawBytes, byte(r))
	}
	return string(rawBytes)
}

type fetcherData struct {
	Connections    []*connection
	ReadableRanges [][2]int64 `json:",omitempty"`
}

type FetcherManager struct {
}

func (fm *FetcherManager) Name() string {
	return "http"
}

func (fm *FetcherManager) Filters() []*fetcher.SchemeFilter {
	return []*fetcher.SchemeFilter{
		{
			Type:    fetcher.FilterTypeUrl,
			Pattern: "HTTP",
		},
		{
			Type:    fetcher.FilterTypeUrl,
			Pattern: "HTTPS",
		},
	}
}

func (fm *FetcherManager) Build() fetcher.Fetcher {
	return &Fetcher{}
}

func (fm *FetcherManager) ParseName(u string) string {
	var name string
	url, err := url.Parse(u)
	if err != nil {
		return ""
	}
	// Get filePath by URL
	name = path.Base(url.Path)
	// If file name is empty, use host name
	if name == "" || name == "/" || name == "." {
		name = url.Hostname()
	}
	return name
}

func (fm *FetcherManager) AutoRename() bool {
	return true
}

func (fm *FetcherManager) DefaultConfig() any {
	return &config{
		UserAgent:   "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36",
		Connections: 16,
	}
}

func (fm *FetcherManager) Store(f fetcher.Fetcher) (data any, err error) {
	_f := f.(*Fetcher)
	_f.helpLock.Lock()
	defer _f.helpLock.Unlock()
	connections := make([]*connection, len(_f.connections))
	for i, c := range _f.connections {
		c.mu.RLock()
		part := *c.Chunk
		connections[i] = &connection{Chunk: &part, Downloaded: c.Downloaded, Completed: c.Completed}
		c.mu.RUnlock()
	}
	return &fetcherData{
		Connections:    connections,
		ReadableRanges: _f.readable.snapshot(),
	}, nil
}

func (fm *FetcherManager) Restore() (v any, f func(meta *fetcher.FetcherMeta, v any) fetcher.Fetcher) {
	return &fetcherData{}, func(meta *fetcher.FetcherMeta, v any) fetcher.Fetcher {
		fd := v.(*fetcherData)
		fb := &FetcherManager{}
		fetcher := fb.Build().(*Fetcher)
		fetcher.meta = meta
		base.ParseReqExtra[fhttp.ReqExtra](fetcher.meta.Req)
		base.ParseOptsExtra[fhttp.OptsExtra](fetcher.meta.Opts)
		if len(fd.Connections) > 0 {
			fetcher.connections = fd.Connections
		}
		if len(fd.ReadableRanges) > 0 && meta.Res != nil && meta.Res.Range {
			fetcher.readable.initialized = true
			for _, span := range fd.ReadableRanges {
				if span[0] >= 0 && span[1] > span[0] && span[1] <= meta.Res.Size {
					fetcher.readable.add(span[0], span[1])
				}
			}
		}
		return fetcher
	}
}

func (fm *FetcherManager) Close() error {
	return nil
}
