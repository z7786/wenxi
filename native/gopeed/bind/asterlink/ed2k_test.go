package gopeed

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/engine"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/piece"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"github.com/GopeedLab/gopeed/internal/outputfile"
)

type edSeedEvents struct {
	ready chan engine.Progress
	ended chan *engine.Error
}

func (s *edSeedEvents) SetProgress(_ engine.RunID, p engine.Progress) {
	select {
	case s.ready <- p:
	default:
	}
}
func (s *edSeedEvents) SendEnded(_ engine.RunID, e *engine.Error) { s.ended <- e }
func (*edSeedEvents) SetNetwork(engine.Network)                   {}
func edSeed(t *testing.T, data []byte) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	folder := t.TempDir()
	file := filepath.Join(folder, "source.bin")
	if err = os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	var h piece.FileHasher
	h.Write(data)
	url := fmt.Sprintf("ed2k://|file|source.bin|%d|%s|/", len(data), h.FileHash())
	events := &edSeedEvents{ready: make(chan engine.Progress, 100), ended: make(chan *engine.Error, 2)}
	e, err := engine.Start(engine.Config{Version: "AsterLink test", DataFolder: filepath.Join(folder, "state"), Port: port}, events)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { e.Close() })
	e.Post(engine.RunCommand{ID: 1, Mode: engine.ModeSeed, Link: url, File: file})
	for {
		select {
		case p := <-events.ready:
			if p.Received == int64(len(data)) {
				return url + fmt.Sprintf("|sources,127.0.0.1:%d|/", port)
			}
		case err := <-events.ended:
			t.Fatal("seed failed:", err)
		case <-time.After(10 * time.Second):
			t.Fatal("seed timeout")
		}
	}
}
func TestED2KDirectOutputRestartAndRemoval(t *testing.T) {
	data := make([]byte, 2*1024*1024)
	for i := range data {
		data[i] = byte((i*17 + i/61) % 251)
	}
	url := edSeed(t, data)
	stateDir, payload, key := openTestCore(t)
	input := request{ID: "ed2k-resume", URL: url, Connections: 1, OutputPath: directFile(t, []byte("old contents")), OutputKey: "stable-ed2k-output", SpeedLimit: 512 * 1024}
	raw, _ := json.Marshal(input)
	if err := Begin(string(raw)); err != nil {
		t.Fatal(err)
	}
	state := waitState(t, input.ID, func(s snapshot) bool { return s.Downloaded > 0 || s.Status == "error" })
	if state.Status == "error" {
		t.Fatal(state.Error)
	}
	logical := filepath.Join(payload, input.ID, "payload.gopeed")
	assertNoPrivateOutput(t, logical)
	taskID := taskIDs[input.ID]
	if err := Pause(input.ID); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(input.OutputPath)
	time.Sleep(100 * time.Millisecond)
	after, _ := os.ReadFile(input.OutputPath)
	if !bytes.Equal(before, after) {
		t.Fatal("writer continued after pause")
	}
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	assertOutputNotPersisted(t, stateDir, key, input.OutputPath)
	// Android reopens a different descriptor for the same stable document key.
	oldPath := input.OutputPath
	input.OutputPath += "-reopened"
	if err := os.Rename(oldPath, input.OutputPath); err != nil {
		t.Fatal(err)
	}
	if err := Open(stateDir, payload, key); err != nil {
		t.Fatal(err)
	}
	input.SpeedLimit = 0
	info, _ := os.Stat(input.OutputPath)
	resume, resumeErr := ed2kRuntime.HasResume(core.GetTask(taskID).Meta.Res.Hash, logical, int64(len(data)), info.Size())
	if !resume || resumeErr != nil {
		t.Fatalf("valid checkpoint missing: %v", resumeErr)
	}
	raw, _ = json.Marshal(input)
	if err := Begin(string(raw)); err != nil {
		t.Fatal(err)
	}
	if taskIDs[input.ID] != taskID {
		t.Fatal("valid ED2K resume replaced its native task")
	}
	state = waitState(t, input.ID, func(s snapshot) bool { return s.Status == "done" || s.Status == "error" }, 35*time.Second)
	if state.Status != "done" {
		t.Fatal(state.Error)
	}
	if state.Path != input.OutputPath {
		t.Fatal("stale output binding returned")
	}
	if err := Pause(input.ID); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(input.OutputPath)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatal("download mismatch:", err)
	}
	assertNoPrivateOutput(t, logical)
	if err = Remove(input.ID); err != nil {
		t.Fatal(err)
	}
	if err = Close(); err != nil {
		t.Fatal(err)
	}
	if err = Open(stateDir, payload, key); err != nil {
		t.Fatal(err)
	}
	if _, err = Snapshot(input.ID); err == nil {
		t.Fatal("deleted task restored")
	}
	// Check the versioned ED2K state is held inside the encrypted database.
	rawState, err := ed2kRuntimeState(t, stateDir, key)
	if err != nil {
		t.Fatal(err)
	}
	if len(rawState.Transfers) != 0 {
		t.Fatal("deleted checkpoint restored")
	}
	if err = os.Remove(input.OutputPath); err != nil {
		t.Fatal("output handle remains open:", err)
	}
	outputfile.Remove(input.ID)
}
func ed2kRuntimeState(t *testing.T, dir, key string) (store.State, error) {
	t.Helper()
	// Open already owns the encrypted store; use the embedding hook through
	// a separate close/reopen to verify disk persistence, not only memory.
	if err := Close(); err != nil {
		return store.State{}, err
	}
	decodedKey, err := base64.StdEncoding.DecodeString(key)
	if err != nil {
		return store.State{}, err
	}
	s, err := newEncryptedStorage(dir, decodedKey)
	if err != nil {
		return store.State{}, err
	}
	defer s.Close()
	var raw []byte
	_, err = s.Get("ed2k", "state", &raw)
	if err != nil {
		return store.State{}, err
	}
	return store.Decode(raw)
}
