package gopeed

// AsterLink uses Gopeed's BitTorrent fetcher and its pinned anacrolix engine.
// Metadata discovery is separate from payload downloads so cancel never waits
// for an unreachable swarm while holding the normal download API lock.
import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/GopeedLab/gopeed/internal/btpolicy"
	"github.com/GopeedLab/gopeed/internal/outputfile"
	corebt "github.com/GopeedLab/gopeed/internal/protocol/bt"
	"github.com/GopeedLab/gopeed/pkg/base"
	"github.com/GopeedLab/gopeed/pkg/download"
	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

const torrentLimit = 4 * 1024 * 1024
const torrentPrefix = "data:application/x-bittorrent;base64,"

var torrentMu sync.Mutex
var metadataJobs = map[string]*metadataJob{}
var metadataWorkers = make(chan struct{}, 1)

type torrentFile struct {
	Index int    `json:"index"`
	Path  string `json:"path"`
	Size  int64  `json:"size"`
}
type torrentInfo struct {
	Hash        string        `json:"hash"`
	Name        string        `json:"name"`
	Data        string        `json:"data"`
	Files       []torrentFile `json:"files"`
	PieceLength int64         `json:"pieceLength"`
}
type metadataState struct {
	Status string       `json:"status"`
	Error  string       `json:"error,omitempty"`
	Info   *torrentInfo `json:"info,omitempty"`
}
type metadataJob struct {
	cancel context.CancelFunc
	state  metadataState
	cause  error // Kept private: native network errors can include tracker credentials.
}

var reservedTorrentName = regexp.MustCompile(`(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)`)

func safeTorrentPart(part string) bool {
	return part != "" && len(part) <= 220 && part != "." && part != ".." &&
		!strings.ContainsAny(part, "<>:\"/\\|?*\x00") && !strings.ContainsFunc(part, func(r rune) bool { return r < 32 }) &&
		strings.TrimRight(part, ". ") == part && !reservedTorrentName.MatchString(part)
}

func parseTorrent(data string) (*metainfo.MetaInfo, *torrentInfo, error) {
	if !strings.HasPrefix(data, torrentPrefix) || len(data) > torrentLimit*4/3+100 {
		return nil, nil, errors.New("种子格式无效或超过 4 MiB")
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(data, torrentPrefix))
	if err != nil || len(raw) == 0 || len(raw) > torrentLimit {
		return nil, nil, errors.New("种子格式无效或超过 4 MiB")
	}
	mi, err := metainfo.Load(bytes.NewReader(raw))
	if err != nil {
		return nil, nil, errors.New("种子内容损坏或格式不受支持")
	}
	info, err := mi.UnmarshalInfo()
	if err != nil || !safeTorrentPart(info.BestName()) || info.PieceLength <= 0 || info.PieceLength > 64*1024*1024 || len(info.Pieces) == 0 || len(info.Pieces)%20 != 0 {
		return nil, nil, errors.New("当前支持含 v1 信息的 BT 种子")
	}
	result := &torrentInfo{Hash: mi.HashInfoBytes().String(), Name: info.BestName(), Data: data, PieceLength: info.PieceLength}
	all := info.UpvertedFiles()
	if len(all) == 0 || len(all) > 10000 {
		return nil, nil, errors.New("种子文件数量无效或超过 10000")
	}
	seen := map[string]bool{}
	var total int64
	for i, file := range all {
		parts := []string{info.BestName()}
		if len(info.Files) > 0 {
			parts = append(parts, file.BestPath()...)
		}
		if len(parts) > 33 || file.Length < 0 || file.Length > (1<<62)-total {
			return nil, nil, errors.New("种子文件长度或目录层级无效")
		}
		for _, part := range parts {
			if !safeTorrentPart(part) {
				return nil, nil, errors.New("种子包含不安全的文件路径")
			}
		}
		name := strings.Join(parts, "/")
		key := strings.ToLower(name)
		if seen[key] {
			return nil, nil, errors.New("种子包含重复文件路径")
		}
		seen[key] = true
		result.Files = append(result.Files, torrentFile{Index: i, Path: name, Size: file.Length})
		total += file.Length
	}
	if total <= 0 || int64(len(info.Pieces)/20) != (total+info.PieceLength-1)/info.PieceLength {
		return nil, nil, errors.New("种子分片校验信息不完整")
	}
	return mi, result, nil
}

// ResolveTorrent starts a cancellable metadata-only operation. A magnet link
// does not select pieces; local .torrent input does not need a network client.
func ResolveTorrent(value string) error {
	var req struct {
		ID  string `json:"id"`
		URL string `json:"url"`
	}
	if json.Unmarshal([]byte(value), &req) != nil || !safeID.MatchString(req.ID) {
		return errors.New("invalid torrent request")
	}
	apiMu.Lock()
	root := payloadRoot
	opened := core != nil
	apiMu.Unlock()
	if !opened {
		return errors.New("Gopeed is not initialized")
	}
	if !strings.HasPrefix(req.URL, torrentPrefix) {
		u, err := url.Parse(req.URL)
		if err != nil || u.Scheme != "magnet" || !strings.HasPrefix(strings.ToLower(u.Query().Get("xt")), "urn:btih:") || len(req.URL) > 65536 {
			return errors.New("invalid magnet URI")
		}
	}
	torrentMu.Lock()
	if len(metadataJobs) > 0 {
		torrentMu.Unlock()
		return errors.New("已有种子正在解析，请先取消")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	job := &metadataJob{cancel: cancel, state: metadataState{Status: "resolving"}}
	metadataJobs[req.ID] = job
	torrentMu.Unlock()
	go func() {
		defer cancel()
		select {
		case metadataWorkers <- struct{}{}:
			defer func() { <-metadataWorkers }()
		case <-ctx.Done():
			return
		}
		if ctx.Err() != nil {
			return
		}
		data := req.URL
		var info *torrentInfo
		var err error
		if !strings.HasPrefix(data, torrentPrefix) {
			var dir string
			dir, err = os.MkdirTemp(root, "torrent-metadata-")
			if err == nil {
				// This directory is generated directly beneath the app-owned cache.
				defer os.RemoveAll(dir)
				cfg := torrent.NewDefaultClientConfig()
				cfg.DataDir = dir
				metadataStorage := storage.NewFileWithCompletion(dir, storage.NewMapPieceCompletion())
				defer metadataStorage.Close()
				cfg.DefaultStorage = metadataStorage
				cfg.ListenPort = 0
				cfg.Seed = false
				cfg.NoUpload = true
				cfg.DisableWebseeds = true
				cfg.DisableWebtorrent = true
				btpolicy.Configure(cfg)
				cfg.EstablishedConnsPerTorrent = 48
				var client *torrent.Client
				client, err = torrent.NewClient(cfg)
				if err == nil {
					var t *torrent.Torrent
					t, err = client.AddMagnet(req.URL)
					if err == nil {
						btpolicy.Restore(t)
						select {
						case <-ctx.Done():
							err = ctx.Err()
						case <-t.GotInfo():
							btpolicy.Remember(t)
							mi := t.Metainfo()
							var buffer bytes.Buffer
							err = mi.Write(&buffer)
							if buffer.Len() > torrentLimit {
								err = errors.New("torrent too large")
							}
							if err == nil {
								data = torrentPrefix + base64.StdEncoding.EncodeToString(buffer.Bytes())
							}
						}
					}
					btpolicy.RememberDHT(client)
					client.Close()
				}
			}
		}
		if err == nil {
			_, info, err = parseTorrent(data)
		}
		torrentMu.Lock()
		defer torrentMu.Unlock()
		if metadataJobs[req.ID] != job {
			return
		}
		if err != nil {
			job.cause = err
			message := "无法获取种子信息，请检查链接、网络或做种人数后重试"
			if strings.HasPrefix(req.URL, torrentPrefix) {
				message = "种子损坏、路径不安全或格式不受支持"
			}
			if errors.Is(err, context.DeadlineExceeded) {
				message = "获取种子信息超时，可能暂无可连接的做种者"
			}
			job.state = metadataState{Status: "error", Error: message}
		} else {
			job.state = metadataState{Status: "ready", Info: info}
		}
	}()
	return nil
}

func TorrentMetadata(id string) (string, error) {
	torrentMu.Lock()
	defer torrentMu.Unlock()
	job := metadataJobs[id]
	if job == nil {
		return "", errors.New("torrent metadata job not found")
	}
	data, err := json.Marshal(job.state)
	return string(data), err
}
func CancelTorrent(id string) {
	torrentMu.Lock()
	defer torrentMu.Unlock()
	if job := metadataJobs[id]; job != nil {
		job.cancel()
		delete(metadataJobs, id)
	}
}
func closeTorrentMetadata() {
	torrentMu.Lock()
	defer torrentMu.Unlock()
	for id, job := range metadataJobs {
		job.cancel()
		delete(metadataJobs, id)
	}
}

func beginTorrent(input request) error {
	if input.BTUploadLimit != nil {
		btpolicy.SetUploadLimit(*input.BTUploadLimit)
	}
	_, info, err := parseTorrent(input.TorrentData)
	if err != nil {
		return err
	}
	if input.TorrentIndex < 0 || input.TorrentIndex >= len(info.Files) {
		return errors.New("invalid torrent file selection")
	}
	chosen := info.Files[input.TorrentIndex]
	corebt.SetAsterLinkLimit(input.SpeedLimit)
	dir, err := taskPayloadDirectory(input)
	if err != nil {
		return err
	}
	if taskID, ok := taskIDs[input.ID]; ok {
		task := core.GetTask(taskID)
		if task != nil {
			if err = core.PauseAndSave(taskID); err != nil {
				return err
			}
		}
		if task != nil && task.Protocol == "bt" && outputMatches(task, input) && task.Meta.Res != nil && task.Meta.Res.Hash == info.Hash && task.Meta.Opts != nil && filepath.Clean(task.Meta.Opts.Path) == dir && len(task.Meta.Opts.SelectFiles) == 1 && task.Meta.Opts.SelectFiles[0] == input.TorrentIndex {
			if input.BTUploadLimit != nil {
				task.Meta.Req.Labels["asterlinkBTUploadLimit"] = strconv.FormatInt(*input.BTUploadLimit, 10)
			}
			if err = bindOutput(input, torrentTaskPath(task)); err != nil {
				return err
			}
			if task.Status == base.DownloadStatusDone {
				path := torrentTaskPath(task)
				st, e := outputfile.Stat(path)
				if e == nil && st.Mode().IsRegular() && st.Size() == chosen.Size {
					remember(&download.Event{Task: task})
					return nil
				}
			} else {
				// BT rechecks piece hashes on every reopen, including evicted cache files.
				task.Meta.Req.Labels["asterlinkBTRecheck"] = "1"
				stateMu.Lock()
				progress := states[input.ID]
				progress.Status, progress.Error = "running", ""
				progress.Path = snapshotOutputPath(task, torrentTaskPath(task))
				states[input.ID] = progress
				stateMu.Unlock()
				return core.ContinueBatch(&download.TaskFilter{IDs: []string{taskID}})
			}
		}
		if err = removeLocked(input.ID); err != nil {
			return err
		}
	}
	// The upstream BT storage is keyed by infohash. Never let two active tasks
	// point that torrent at different output directories.
	for id, taskID := range taskIDs {
		task := core.GetTask(taskID)
		if id != input.ID && task != nil && task.Protocol == "bt" && task.Status != base.DownloadStatusPause && task.Status != base.DownloadStatusDone {
			return errors.New("BT tasks must be scheduled serially")
		}
	}
	if err = clearTaskPayload(dir); err != nil {
		return err
	}
	logical := filepath.Join(dir, chosen.Path)
	if err = bindOutput(input, logical); err != nil {
		return err
	}
	if err = outputfile.Reset(logical, chosen.Size); err != nil {
		outputfile.Remove(input.ID)
		return err
	}
	token := fmt.Sprintf("%s-%d", input.ID, time.Now().UnixNano())
	uploadLimit := btpolicy.DefaultUploadLimit
	if input.BTUploadLimit != nil {
		uploadLimit = *input.BTUploadLimit
	}
	req := &base.Request{URL: input.TorrentData, Labels: map[string]string{"asterlinkId": input.ID, "asterlinkGeneration": token,
		"asterlinkBTPath": dir, "asterlinkBTUploadLimit": strconv.FormatInt(uploadLimit, 10)}}
	if input.OutputKey != "" {
		req.Labels[outputKeyLabel] = input.OutputKey
	}
	stateMu.Lock()
	generations[input.ID] = token
	states[input.ID] = snapshot{Status: "running", Total: chosen.Size, Path: input.OutputPath}
	stateMu.Unlock()
	taskID, err := core.CreateDirect(req, &base.Options{Path: dir, SelectFiles: []int{input.TorrentIndex}})
	if err != nil {
		outputfile.Remove(input.ID)
		return err
	}
	taskIDs[input.ID] = taskID
	return nil
}

func torrentTaskPath(task *download.Task) string {
	if task.Meta == nil || task.Meta.Res == nil || task.Meta.Opts == nil || len(task.Meta.Opts.SelectFiles) != 1 {
		return ""
	}
	index := task.Meta.Opts.SelectFiles[0]
	if index < 0 || index >= len(task.Meta.Res.Files) {
		return ""
	}
	f := task.Meta.Res.Files[index]
	return filepath.Join(task.Meta.Opts.Path, task.Meta.Res.Name, f.Path, f.Name)
}
