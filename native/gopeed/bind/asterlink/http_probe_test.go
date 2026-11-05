package gopeed

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHTTPProbeBoundedBodyValidation(t *testing.T) {
	for _, mode := range []string{"valid", "wrong-range", "expanded-range", "error-page", "partial-body", "full-sample", "encoded-range"} {
		t.Run(mode, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Range") != "bytes=0-63" || r.Header.Get("Accept-Encoding") != "identity" {
					t.Error("body probe does not use download range headers")
				}
				body := "Hello World!\n"
				if mode == "error-page" {
					body = strings.Repeat("x", 65)
					w.Write([]byte(body))
					return
				}
				if mode == "full-sample" {
					w.Write([]byte(strings.Repeat("a", 1000)))
					return
				}
				end := len(body) - 1
				if mode == "wrong-range" {
					end++
				}
				if mode == "expanded-range" {
					body = strings.Repeat("x", 65)
				}
				if mode == "encoded-range" {
					w.Header().Set("Content-Encoding", "gzip")
				}
				w.Header().Set("Content-Range", fmt.Sprintf("bytes 0-%d/13", end))
				if mode == "partial-body" {
					w.Header().Set("Content-Length", "13")
					body = "a"
				}
				w.WriteHeader(http.StatusPartialContent)
				w.Write([]byte(body))
			}))
			defer server.Close()
			input, _ := json.Marshal(httpProbeInput{ID: "body-test", URL: server.URL, ReadLimit: 64, SampleOnly: mode == "full-sample"})
			if err := StartHttpProbe(string(input)); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { StopHttpProbe("body-test") })
			result := waitProbeTest(t, "body-test")
			if mode == "valid" || mode == "full-sample" {
				body, err := base64.StdEncoding.DecodeString(result.Body)
				if result.Status != "done" || err != nil || mode == "valid" && string(body) != "Hello World!\n" || mode == "full-sample" && len(body) != 64 {
					t.Fatalf("valid body not read: %+v", result)
				}
			} else if result.Status != "error" || mode == "partial-body" && result.ErrorKind != "network" || mode != "partial-body" && result.ErrorKind != "content" {
				t.Fatalf("invalid body accepted or mislabeled: %+v", result)
			}
		})
	}
}

func startProbeTest(t *testing.T, id, address string) {
	t.Helper()
	data, _ := json.Marshal(httpProbeInput{ID: id, URL: address, Headers: map[string]string{"Cookie": "probe-secret=fixture"}})
	if err := StartHttpProbe(string(data)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { StopHttpProbe(id) })
}

func waitProbeTest(t *testing.T, id string) httpProbeResult {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		data, err := HttpProbeStatus(id)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(data, "probe-secret") || strings.Contains(data, "fixture-token") {
			t.Fatal("probe exposed credentials")
		}
		var result httpProbeResult
		if err := json.Unmarshal([]byte(data), &result); err != nil {
			t.Fatal(err)
		}
		if result.Status != "running" {
			return result
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("probe did not finish")
	return httpProbeResult{}
}

func TestHTTPProbeRangeMetadataAndRelativeRedirect(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "bytes=0-0" || r.Header.Get("Accept-Encoding") != "identity" || r.Header.Get("Cookie") != "probe-secret=fixture" {
			t.Error("probe lost its range or request headers")
		}
		if r.URL.Path == "/start" {
			http.Redirect(w, r, "media/list.m3u8", http.StatusFound)
			return
		}
		w.Header().Set("Content-Range", "bytes 0-0/12345")
		w.Header().Set("Content-Length", "1")
		w.Header().Set("ETag", `"version-a"`)
		w.Header().Set("Set-Cookie", "probe-secret=must-not-return")
		w.WriteHeader(http.StatusPartialContent)
		w.Write([]byte{'a'})
	}))
	defer server.Close()
	startProbeTest(t, "metadata", server.URL+"/start?token=fixture-token")
	result := waitProbeTest(t, "metadata")
	if result.Status != "done" || result.Code != 206 || result.Headers["content-range"] != "bytes 0-0/12345" || !result.HLSPath || result.Headers["etag"] != `"version-a"` {
		t.Fatalf("unexpected probe metadata: %+v", result)
	}
	if _, ok := result.Headers["set-cookie"]; ok {
		t.Fatal("probe returned an unneeded sensitive header")
	}
}

func TestHTTPProbeEmptyAndRetryAfter(t *testing.T) {
	for _, status := range []int{416, 429, 503} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Range", "bytes */0")
				w.Header().Set("Retry-After", "7")
				w.WriteHeader(status)
			}))
			defer server.Close()
			startProbeTest(t, "status", server.URL)
			result := waitProbeTest(t, "status")
			if result.Status != "done" || result.Code != status || result.Headers["retry-after"] != "7" || result.Headers["content-range"] != "bytes */0" {
				t.Fatalf("HTTP status/headers changed: %+v", result)
			}
		})
	}
}

func TestHTTPProbeDoesNotReadAnUnboundedBody(t *testing.T) {
	closed := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "1000000000")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(closed)
	}))
	defer server.Close()
	startProbeTest(t, "bounded", server.URL)
	result := waitProbeTest(t, "bounded")
	if result.Status != "done" || result.Headers["content-length"] != "1000000000" {
		t.Fatalf("probe waited for body: %+v", result)
	}
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("probe did not close the stream")
	}
}

func TestHTTPProbeCertificateFailureIsNotRetryable(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("request passed an untrusted certificate")
	}))
	defer server.Close()
	startProbeTest(t, "certificate", server.URL+"/?token=fixture-token")
	result := waitProbeTest(t, "certificate")
	if result.Status != "error" || result.ErrorKind != "certificate" || result.Retryable {
		t.Fatalf("certificate error changed: %+v", result)
	}
}

func TestHTTPProbeInterruptedConnectionIsRetryable(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, _ := w.(http.Hijacker).Hijack()
		conn.Close()
	}))
	defer server.Close()
	startProbeTest(t, "interrupted", server.URL)
	result := waitProbeTest(t, "interrupted")
	if result.Status != "error" || result.ErrorKind != "network" || !result.Retryable {
		t.Fatalf("interruption lost retryability: %+v", result)
	}
}

func TestHTTPProbeCancelAndReplacement(t *testing.T) {
	started, closed := make(chan struct{}), make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/slow" {
			close(started)
			<-r.Context().Done()
			close(closed)
			return
		}
		w.Header().Set("Content-Length", "4")
		w.Write([]byte("next"))
	}))
	defer server.Close()
	startProbeTest(t, "replace", server.URL+"/slow")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("probe did not start")
	}
	startProbeTest(t, "replace", server.URL+"/next")
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("old probe was not cancelled promptly")
	}
	if result := waitProbeTest(t, "replace"); result.Status != "done" || result.Headers["content-length"] != "4" {
		t.Fatalf("old result replaced the new probe: %+v", result)
	}
	StopHttpProbe("replace")
	if result := waitProbeTest(t, "replace"); result.Status != "cancelled" {
		t.Fatalf("stop left a probe registered: %+v", result)
	}
}
