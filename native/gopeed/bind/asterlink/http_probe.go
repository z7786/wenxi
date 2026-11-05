package gopeed

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type httpProbeInput struct {
	ID         string            `json:"id"`
	URL        string            `json:"url"`
	Headers    map[string]string `json:"headers"`
	ReadLimit  int               `json:"readLimit,omitempty"`
	SampleOnly bool              `json:"sampleOnly,omitempty"`
}

type httpProbeResult struct {
	Status    string            `json:"status"`
	Code      int               `json:"code,omitempty"`
	Headers   map[string]string `json:"headers,omitempty"`
	HLSPath   bool              `json:"hlsPath,omitempty"`
	ErrorKind string            `json:"errorKind,omitempty"`
	Retryable bool              `json:"retryable,omitempty"`
	Body      string            `json:"body,omitempty"`
	Host      string            `json:"host,omitempty"`
}

type httpProbeJob struct {
	cancel context.CancelFunc
	result httpProbeResult
}

var httpProbes = struct {
	sync.Mutex
	jobs map[string]*httpProbeJob
}{jobs: map[string]*httpProbeJob{}}

func probeURI(value string) (*url.URL, error) {
	uri, err := url.Parse(value)
	if err != nil || uri == nil || uri.Hostname() == "" || uri.User != nil || (uri.Scheme != "https" && uri.Scheme != "http") {
		return nil, errors.New("invalid probe URL")
	}
	return uri, nil
}

// StartHttpProbe performs only a bounded capability read, without creating a
// download or persisting its signed URL. Polling keeps native control responsive.
func StartHttpProbe(value string) error {
	var input httpProbeInput
	if len(value) > 64*1024 || json.Unmarshal([]byte(value), &input) != nil || !safeID.MatchString(input.ID) || input.ReadLimit < 0 || input.ReadLimit > 64*1024 {
		return errors.New("invalid HTTP probe")
	}
	if _, err := probeURI(input.URL); err != nil {
		return err
	}
	httpProbes.Lock()
	defer httpProbes.Unlock()
	if previous := httpProbes.jobs[input.ID]; previous != nil {
		previous.cancel()
	} else if len(httpProbes.jobs) >= 16 {
		return errors.New("too many HTTP probes")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	job := &httpProbeJob{cancel: cancel, result: httpProbeResult{Status: "running"}}
	httpProbes.jobs[input.ID] = job
	go func() {
		defer cancel()
		transport := &http.Transport{
			DialContext:            (&net.Dialer{Timeout: 20 * time.Second}).DialContext,
			TLSHandshakeTimeout:    20 * time.Second,
			ResponseHeaderTimeout:  20 * time.Second,
			MaxResponseHeaderBytes: 64 * 1024,
			TLSClientConfig:        &tls.Config{},
		}
		defer transport.CloseIdleConnections()
		client := &http.Client{Transport: transport, CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > 5 {
				return errors.New("too many probe redirects")
			}
			_, err := probeURI(req.URL.String())
			return err
		}}
		result := performHTTPProbe(ctx, input, client)
		httpProbes.Lock()
		if httpProbes.jobs[input.ID] == job {
			job.result = result
		}
		httpProbes.Unlock()
	}()
	return nil
}

func performHTTPProbe(ctx context.Context, input httpProbeInput, client *http.Client) httpProbeResult {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, input.URL, nil)
	if err != nil {
		return httpProbeResult{Status: "error", ErrorKind: "request"}
	}
	for key, value := range input.Headers {
		req.Header.Set(key, value)
	}
	probeBytes := 1
	if input.ReadLimit > 0 {
		probeBytes = input.ReadLimit
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=0-%d", probeBytes-1))
	req.Header.Del("If-Range")
	req.Header.Set("Accept-Encoding", "identity")
	response, err := client.Do(req)
	if err != nil {
		kind, retryable := "network", true
		var certificate *tls.CertificateVerificationError
		var unknown x509.UnknownAuthorityError
		var hostname x509.HostnameError
		var invalid x509.CertificateInvalidError
		if errors.As(err, &certificate) || errors.As(err, &unknown) || errors.As(err, &hostname) || errors.As(err, &invalid) {
			kind, retryable = "certificate", false
		} else if errors.Is(err, context.Canceled) {
			kind, retryable = "cancelled", false
		} else {
			var network net.Error
			retryable = errors.As(err, &network) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF)
		}
		return httpProbeResult{Status: "error", ErrorKind: kind, Retryable: retryable}
	}
	defer response.Body.Close()
	var body []byte
	if input.ReadLimit > 0 && response.StatusCode >= 200 && response.StatusCode < 300 {
		if encoding := response.Header.Get("Content-Encoding"); encoding != "" && !strings.EqualFold(encoding, "identity") {
			return httpProbeResult{Status: "error", ErrorKind: "content"}
		}
		limit := int64(input.ReadLimit) + 1
		if input.SampleOnly && response.StatusCode == http.StatusOK {
			limit = int64(input.ReadLimit)
		}
		body, err = io.ReadAll(io.LimitReader(response.Body, limit))
		if err != nil {
			return httpProbeResult{Status: "error", ErrorKind: "network", Retryable: true}
		}
		if (len(body) == 0 && !input.SampleOnly) || len(body) > input.ReadLimit {
			return httpProbeResult{Status: "error", ErrorKind: "content"}
		}
		if response.StatusCode == http.StatusPartialContent {
			match := regexp.MustCompile(`^bytes 0-(\d+)/(\d+)$`).FindStringSubmatch(response.Header.Get("Content-Range"))
			if len(match) != 3 {
				return httpProbeResult{Status: "error", ErrorKind: "content"}
			}
			end, e1 := strconv.ParseInt(match[1], 10, 64)
			total, e2 := strconv.ParseInt(match[2], 10, 64)
			if e1 != nil || e2 != nil || end+1 != int64(len(body)) || total <= end || end != min(total, int64(input.ReadLimit))-1 {
				return httpProbeResult{Status: "error", ErrorKind: "content"}
			}
		}
	}
	// A server ignoring Range must not make this probe download its whole body.
	if input.ReadLimit == 0 && response.StatusCode == http.StatusPartialContent {
		if _, err := io.CopyN(io.Discard, response.Body, 1); err != nil {
			return httpProbeResult{Status: "error", ErrorKind: "network", Retryable: true}
		}
	}
	headers := map[string]string{}
	for _, key := range []string{"Content-Length", "Content-Range", "Content-Type", "ETag", "Last-Modified", "Retry-After"} {
		if value := response.Header.Get(key); value != "" {
			headers[strings.ToLower(key)] = value
		}
	}
	hls := strings.HasSuffix(strings.ToLower(req.URL.Path), ".m3u8") || strings.HasSuffix(strings.ToLower(response.Request.URL.Path), ".m3u8")
	return httpProbeResult{Status: "done", Code: response.StatusCode, Headers: headers, HLSPath: hls, Body: base64.StdEncoding.EncodeToString(body), Host: response.Request.URL.Hostname()}
}

func HttpProbeStatus(id string) (string, error) {
	if !safeID.MatchString(id) {
		return "", errors.New("invalid HTTP probe ID")
	}
	httpProbes.Lock()
	defer httpProbes.Unlock()
	job := httpProbes.jobs[id]
	if job == nil {
		return `{"status":"cancelled"}`, nil
	}
	data, err := json.Marshal(job.result)
	return string(data), err
}

func StopHttpProbe(id string) {
	httpProbes.Lock()
	defer httpProbes.Unlock()
	if job := httpProbes.jobs[id]; job != nil {
		job.cancel()
		delete(httpProbes.jobs, id)
	}
}

func closeHTTPProbes() {
	httpProbes.Lock()
	defer httpProbes.Unlock()
	for id, job := range httpProbes.jobs {
		job.cancel()
		delete(httpProbes.jobs, id)
	}
}
