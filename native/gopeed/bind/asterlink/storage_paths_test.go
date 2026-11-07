package gopeed

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	ed2kstore "github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

func TestStoragePathRelocationBoundariesAndFirstUpgrade(t *testing.T) {
	old := "/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111"
	home := "/var/mobile/Containers/Data/Application/22222222-2222-2222-2222-222222222222"
	paths := map[string]string{"/old": "/middle", "/middle": "/current", "/old/provider": "/external"}
	for original, want := range map[string]string{
		"/old/file": "/current/file", "/older/file": "/older/file",
		"/old/provider/file": "/external/file", "https://example.test/old/file": "https://example.test/old/file",
		old + "/Documents/file": home + "/Documents/file", old + "-other/Documents/file": old + "-other/Documents/file",
	} {
		if got := relocatedStoragePath(original, paths, home); got != want {
			t.Fatalf("%s relocated to %s, want %s", original, got, want)
		}
	}
	if got := relocatedStoragePath("/a/file", map[string]string{"/a": "/b", "/b": "/a"}, ""); got != "/a/file" {
		t.Fatal("cyclic move was applied")
	}
	if got := relocatedStoragePath("/a/file", map[string]string{"/a": "/a/moved"}, ""); got != "/a/moved/file" {
		t.Fatal("expanding prefix did not terminate")
	}
}

func TestStoragePathRestoreKeepsSourceSecretsAndResumeCheckpoints(t *testing.T) {
	s, err := newEncryptedStorage(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err = s.Setup([]string{"task", "config", "save", "ed2k"}); err != nil {
		t.Fatal(err)
	}
	const old = "/old"
	task := map[string]any{
		"id": "native-id", "status": "pause", "progress": map[string]any{"downloaded": int64(9007199254740993)},
		"meta": map[string]any{
			"opts": map[string]any{"path": old + "/Documents/.asterlink-cache/task", "selectFiles": []int{1}},
			"req": map[string]any{"url": "https://example.test/old/token", "extra": map[string]any{"header": map[string]string{"Cookie": old + "/account-value"}},
				"labels": map[string]any{"asterlinkBTPath": old + "/Documents/.asterlink-cache/task", "asterlinkId": "task"}},
		},
	}
	checkpoint := map[string]any{"Connections": []any{map[string]any{"Chunk": map[string]any{"Begin": 0, "End": 1000, "Downloaded": 750}}}}
	for bucket, value := range map[string]any{"task": task, "config": map[string]any{"downloadDir": old + "/Documents/Downloads"}, "save": checkpoint} {
		if err = s.Put(bucket, "record", value); err != nil {
			t.Fatal(err)
		}
	}
	if err = s.Put("config", "config", map[string]any{"downloadDir": old + "/Documents/Downloads"}); err != nil {
		t.Fatal(err)
	}
	state, err := ed2kstore.Decode(nil)
	if err != nil {
		t.Fatal(err)
	}
	hash := wire.Hash{1}
	state.Transfers[hash] = ed2kstore.Transfer{File: old + "/Documents/.asterlink-cache/task/payload.gopeed", Size: 123456}
	encoded, err := ed2kstore.Encode(state)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Put("ed2k", "state", encoded); err != nil {
		t.Fatal(err)
	}
	if err = s.restorePaths(map[string]string{old: "/current"}, ""); err != nil {
		t.Fatal(err)
	}
	var current map[string]any
	if _, err = s.Get("task", "record", &current); err != nil {
		t.Fatal(err)
	}
	meta := storageObject(current["meta"])
	if storageObject(meta["opts"])["path"] != "/current/Documents/.asterlink-cache/task" {
		t.Fatal("task path did not move")
	}
	req := storageObject(meta["req"])
	if req["url"] != "https://example.test/old/token" {
		t.Fatal("source URL changed")
	}
	if storageObject(storageObject(req["extra"])["header"])["Cookie"] != old+"/account-value" {
		t.Fatal("source credentials changed")
	}
	var exact json.RawMessage
	if _, err = s.Get("task", "record", &exact); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(exact, []byte("9007199254740993")) {
		t.Fatal("large progress counter lost precision")
	}
	if _, err = s.Get("save", "record", &exact); err != nil {
		t.Fatal(err)
	}
	want, _ := json.Marshal(checkpoint)
	if !bytes.Equal(exact, want) {
		t.Fatal("range checkpoints changed")
	}
	if _, err = s.Get("ed2k", "state", &encoded); err != nil {
		t.Fatal(err)
	}
	restored, err := ed2kstore.Decode(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Transfers[hash].File != "/current/Documents/.asterlink-cache/task/payload.gopeed" {
		t.Fatal("ED2K payload path not restored")
	}
	// A corrupt secondary record must roll back the task rewrite as well.
	if err = s.Put("ed2k", "state", []byte("invalid")); err != nil {
		t.Fatal(err)
	}
	if err = s.restorePaths(map[string]string{"/current": "/later"}, ""); err == nil {
		t.Fatal("malformed embedded state accepted")
	}
	if _, err = s.Get("task", "record", &current); err != nil {
		t.Fatal(err)
	}
	if storageObject(storageObject(current["meta"])["opts"])["path"] != "/current/Documents/.asterlink-cache/task" {
		t.Fatal("partial migration committed")
	}
}

func TestHTTPResumeAfterContainerDirectoryMoves(t *testing.T) {
	root := t.TempDir()
	oldHome, newHome := filepath.Join(root, "before"), filepath.Join(root, "after")
	stateDir, payload := filepath.Join(oldHome, "state"), filepath.Join(oldHome, destinationCacheName)
	if err := Open(stateDir, payload, ""); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := Close(); err != nil {
			t.Error(err)
		}
	})
	f := serveFile(t, 1024*1024, 0)
	startFile(t, "container-resume", f.server.URL+"/file", 4, 256*1024)
	waitState(t, "container-resume", func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Pause("container-resume"); err != nil {
		t.Fatal(err)
	}
	before := taskIDs["container-resume"]
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(oldHome, newHome); err != nil {
		t.Fatal(err)
	}
	if err := OpenWithStoragePaths(filepath.Join(newHome, "state"), filepath.Join(newHome, destinationCacheName), "", map[string]string{oldHome: newHome}, ""); err != nil {
		t.Fatal(err)
	}
	if taskIDs["container-resume"] != before {
		t.Fatal("stored native task lost on reopen")
	}
	startFile(t, "container-resume", f.server.URL+"/file", 4, 0)
	if taskIDs["container-resume"] != before {
		t.Fatal("partially completed download restarted from zero")
	}
	final := waitState(t, "container-resume", func(s snapshot) bool { return s.Status == "done" }, 15*time.Second)
	assertPayload(t, final, f.data)
	if filepath.Clean(final.Path) != filepath.Join(newHome, destinationCacheName, "container-resume", "payload.gopeed") {
		t.Fatalf("completed payload has unexpected path %s", final.Path)
	}
}
