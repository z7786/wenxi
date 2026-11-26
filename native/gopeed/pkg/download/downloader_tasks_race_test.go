package download

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/base"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestDownloader_TasksConcurrentAccess(t *testing.T) {
	payload := bytes.Repeat([]byte("0123456789abcdef"), 4*1024)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "item.bin", time.Now(), bytes.NewReader(payload))
	}))
	defer srv.Close()

	d := NewDownloader(&DownloaderConfig{
		Storage:         NewMemStorage(),
		StorageDir:      t.TempDir(),
		RefreshInterval: 10,
	})
	if err := d.Setup(); err != nil {
		t.Fatal(err)
	}
	defer d.Clear()

	outDir := t.TempDir()
	stop := make(chan struct{})
	var readers sync.WaitGroup
	for i := 0; i < 4; i++ {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for {
				select {
				case <-stop:
					return
				default:
					tasks := d.GetTasks()
					for _, task := range tasks {
						_ = d.GetTask(task.ID)
					}
					_ = d.GetTasksByFilter(&TaskFilter{Statuses: []base.Status{base.DownloadStatusRunning}})
					_ = d.GetTasksByFilter(nil)
				}
			}
		}()
	}

	var ids []string
	for i := 0; i < 12; i++ {
		id, err := d.CreateDirect(&base.Request{URL: srv.URL + "/item.bin"}, &base.Options{
			Path:  outDir,
			Extra: &fhttp.OptsExtra{Connections: 2},
		})
		if err != nil {
			t.Fatalf("CreateDirect failed: %v", err)
		}
		ids = append(ids, id)
		if i%3 == 0 {
			_ = d.Delete(&TaskFilter{IDs: []string{id}}, true)
		}
	}
	_ = d.Pause(nil)
	for _, id := range ids {
		_ = d.Delete(&TaskFilter{IDs: []string{id}}, true)
	}

	close(stop)
	readers.Wait()
}
