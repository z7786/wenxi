// Package gopeed embeds the Gopeed 1.8.1 downloader in AsterLink through JNI.
package gopeed

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/GopeedLab/gopeed/internal/btpolicy"
	ed2kengine "github.com/GopeedLab/gopeed/internal/ed2kcore/engine"
	"github.com/GopeedLab/gopeed/internal/fetcher"
	"github.com/GopeedLab/gopeed/internal/outputfile"
	corebt "github.com/GopeedLab/gopeed/internal/protocol/bt"
	coreed2k "github.com/GopeedLab/gopeed/internal/protocol/ed2k"
	corehttp "github.com/GopeedLab/gopeed/internal/protocol/http"
	"github.com/GopeedLab/gopeed/pkg/base"
	"github.com/GopeedLab/gopeed/pkg/download"
	fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

var apiMu sync.Mutex
var stateMu sync.RWMutex
var core *download.Downloader
var ed2kRuntime *coreed2k.Runtime
var payloadRoot string
var taskIDs = map[string]string{}
var states = map[string]snapshot{}
var generations = map[string]string{} // Protected by stateMu, including listener callbacks.
var safeID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,100}$`)

type snapshot struct {
	Status            string                     `json:"status"`
	Total             int64                      `json:"total"`
	Downloaded        int64                      `json:"downloaded"`
	Speed             int64                      `json:"speed"`
	ActiveConnections int                        `json:"activeConnections"`
	TotalConnections  int                        `json:"totalConnections"`
	HTTPCode          int                        `json:"httpCode"`
	RetryAfterMS      int64                      `json:"retryAfterMs"`
	RetryExhausted    bool                       `json:"retryExhausted"`
	ErrorKind         string                     `json:"errorKind"`
	Error             string                     `json:"error"`
	Path              string                     `json:"path"`
	ReadableRanges    [][2]int64                 `json:"readableRanges,omitempty"`
	Aliyun            *fhttp.AliyunTransferState `json:"aliyun,omitempty"`
	BT                *corebt.SourceState        `json:"bt,omitempty"`
}
type request struct {
	ID                string               `json:"id"`
	CacheRoot         string               `json:"cacheRoot,omitempty"`
	OutputPath        string               `json:"outputPath,omitempty"`
	OutputKey         string               `json:"outputKey,omitempty"`
	URL               string               `json:"url"`
	Headers           map[string]string    `json:"headers"`
	NetworkPolicy     *fhttp.NetworkPolicy `json:"networkPolicy,omitempty"`
	Connections       int                  `json:"connections"`
	ConnectionProfile string               `json:"connectionProfile"`
	AliyunGroup       string               `json:"aliyunGroup"`
	Retries           int                  `json:"retries"`
	SpeedLimit        int64                `json:"speedLimit"`
	BTUploadLimit     *int64               `json:"btUploadLimit,omitempty"`
	TorrentData       string               `json:"torrentData"`
	TorrentIndex      int                  `json:"torrentIndex"`
}

func Open(storageDir, cacheDir, encodedKey string) (err error) {
	apiMu.Lock()
	defer apiMu.Unlock()
	if core != nil {
		return nil
	}
	outputfile.Clear()
	key, err := base64.StdEncoding.DecodeString(encodedKey)
	if err != nil || len(key) != 32 {
		return errors.New("invalid download storage key")
	}
	storage, err := newEncryptedStorage(storageDir, key)
	for i := range key {
		key[i] = 0
	}
	if err != nil {
		return err
	}
	payloadRoot, err = filepath.Abs(cacheDir)
	if err == nil {
		err = os.MkdirAll(payloadRoot, 0700)
	}
	if err == nil {
		err = resetStreamCache(payloadRoot)
	}
	if err != nil {
		storage.Close()
		return err
	}
	corebt.SetAsterLinkCache(filepath.Join(payloadRoot, "bt-storage"))
	if err = storage.Setup([]string{"ed2k", "bt-discovery"}); err != nil {
		storage.Close()
		return err
	}
	ed2kRuntime = coreed2k.NewRuntime(filepath.Join(storageDir, "ed2k"), storage)
	engine := download.NewDownloader(&download.DownloaderConfig{
		Storage: storage, StorageDir: storageDir, RefreshInterval: 350,
		FetchManagers: []fetcher.FetcherManager{new(corehttp.FetcherManager), new(corebt.FetcherManager), &coreed2k.FetcherManager{Runtime: ed2kRuntime}},
	})
	engine.Logger.Logger = engine.Logger.Logger.Output(io.Discard)
	engine.ExtensionLogger.Logger = engine.ExtensionLogger.Logger.Output(io.Discard)
	if err = engine.Setup(); err != nil {
		storage.Close()
		return err
	}
	cfg, _ := engine.GetConfig()
	cfg.MaxRunning = 3 // Android's queue further enforces the user's 1..3 setting.
	cfg.DownloadDir = payloadRoot
	if err = engine.PutConfig(cfg); err != nil {
		engine.Close()
		return err
	}
	stateMu.Lock()
	states = map[string]snapshot{}
	generations = map[string]string{}
	stateMu.Unlock()
	taskIDs = map[string]string{}
	for _, task := range engine.GetTasks() {
		if task.Meta == nil || task.Meta.Req == nil {
			continue
		}
		id := task.Meta.Req.Labels["asterlinkId"]
		if !safeID.MatchString(id) {
			continue
		}
		taskIDs[id] = task.ID
		var token [16]byte
		if _, err = rand.Read(token[:]); err != nil {
			engine.Close()
			return err
		}
		task.Meta.Req.Labels["asterlinkGeneration"] = hex.EncodeToString(token[:])
		stateMu.Lock()
		generations[id] = task.Meta.Req.Labels["asterlinkGeneration"]
		stateMu.Unlock()
		remember(&download.Event{Task: task})
	}
	engine.Listener(remember)
	core = engine
	btpolicy.SetUploadLimit(btpolicy.DefaultUploadLimit)
	startDiscoverySaver(storage)
	return nil
}

func remember(event *download.Event) {
	task := event.Task
	if task == nil || task.Meta == nil || task.Meta.Req == nil {
		return
	}
	id := task.Meta.Req.Labels["asterlinkId"]
	value := snapshot{Status: string(task.Status)}
	active, total := task.ConnectionCounts()
	value.TotalConnections = total
	value.Aliyun = task.AliyunTransferState()
	if task.Status == base.DownloadStatusRunning {
		value.BT = task.BTSourceState()
	}
	if task.Status == base.DownloadStatusRunning {
		value.ActiveConnections = active
	}
	if task.Meta.Res != nil {
		value.Total = task.Meta.Res.Size
		value.Path = task.Meta.SingleFilepath()
		if task.Protocol == "bt" {
			value.Path = torrentTaskPath(task)
		}
		value.Path = snapshotOutputPath(task, value.Path)
		if task.Protocol == "http" {
			value.ReadableRanges = task.ReadableRanges()
			if task.Status == base.DownloadStatusDone && value.Total > 0 {
				value.ReadableRanges = [][2]int64{{0, value.Total}}
			}
		}
	}
	if task.Progress != nil {
		value.Downloaded = task.Progress.Downloaded
		if task.Status == base.DownloadStatusRunning {
			value.Speed = task.Progress.Speed
		}
	}
	if event.Err != nil {
		// Resolve has no internal segment retry loop. Allow the caller's bounded
		// task retry there; do not multiply already exhausted segment retries.
		value.RetryExhausted = task.Meta.Res != nil
		var httpError *corehttp.RequestError
		if errors.As(event.Err, &httpError) {
			value.HTTPCode = httpError.Code
			value.ErrorKind = "http"
			value.RetryAfterMS = max(0, time.Until(httpError.RetryAfter).Milliseconds())
		}
		var networkError net.Error
		if errors.As(event.Err, &networkError) || errors.Is(event.Err, io.ErrUnexpectedEOF) {
			value.ErrorKind = "network"
		}
		value.Error = "Gopeed 下载失败，请重试或重新解析链接"
		if task.Protocol == "ed2k" {
			value.Error = "ED2K 下载失败，请重试"
			var ed2kError *ed2kengine.Error
			if errors.As(event.Err, &ed2kError) {
				switch ed2kError.Code {
				case ed2kengine.CodeDiskFull:
					value.Error = "下载磁盘空间不足"
				case ed2kengine.CodeOutputExists:
					value.Error = "ED2K 断点与文件不一致，请删除任务后重新下载"
				case ed2kengine.CodeFileError:
					value.Error = "ED2K 文件读写或校验失败，请检查下载目录后重试"
				case ed2kengine.CodeInvalidLink:
					value.Error = "ED2K 文件链接无效"
				case ed2kengine.CodeTransferBusy:
					value.Error = "相同 ED2K 文件已有下载任务"
				case ed2kengine.CodeStartFailed:
					value.Error = "ED2K 内核启动失败，请重试"
				}
			}
		}
		if value.HTTPCode != 0 {
			value.Error = fmt.Sprintf("服务器返回 %d", value.HTTPCode)
		}
		if os.IsPermission(event.Err) {
			value.Error = "下载目录不可写"
			value.ErrorKind = "storage"
		}
		if errors.Is(event.Err, fhttp.ErrNetworkPolicy) {
			value.Error = "来源下载地址超出声明的网络权限，请更新来源后重试"
			value.ErrorKind = "policy"
			value.RetryExhausted = true
		}
	}
	stateMu.Lock()
	defer stateMu.Unlock()
	if token, ok := generations[id]; !ok || token != task.Meta.Req.Labels["asterlinkGeneration"] {
		return // A deleted task or a previous engine instance cannot replace a new task's state.
	}
	if value.Status == "error" && value.Error == "" {
		value.Error = states[id].Error
		value.HTTPCode = states[id].HTTPCode
		value.RetryAfterMS = states[id].RetryAfterMS
		value.RetryExhausted = states[id].RetryExhausted
		value.ErrorKind = states[id].ErrorKind
	}
	states[id] = value
}

func Begin(value string) error {
	apiMu.Lock()
	defer apiMu.Unlock()
	if core == nil {
		return errors.New("Gopeed is not initialized")
	}
	var input request
	if err := json.Unmarshal([]byte(value), &input); err != nil {
		return err
	}
	if !safeID.MatchString(input.ID) {
		return errors.New("invalid download ID")
	}
	if input.Connections < 1 || input.Connections > 512 {
		return errors.New("connections must be in 1..512")
	}
	if input.ConnectionProfile == "aliyun" && input.AliyunGroup != "" {
		decoded, err := hex.DecodeString(input.AliyunGroup)
		if err != nil || len(decoded) != 32 {
			return errors.New("invalid Aliyun account group")
		}
	}
	if input.Retries < 0 || input.Retries > fhttp.MaxRetryLimit || input.SpeedLimit < 0 {
		return errors.New("invalid retry or speed limit")
	}
	if err := validateOutput(input); err != nil {
		return err
	}
	if input.TorrentData != "" {
		return beginTorrent(input)
	}
	if len(input.URL) >= 5 && strings.EqualFold(input.URL[:5], "ed2k:") {
		return beginEd2k(input)
	}
	parsed, err := url.Parse(input.URL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return errors.New("invalid HTTP download URL")
	}
	if input.NetworkPolicy != nil {
		if err := input.NetworkPolicy.CheckURL(parsed); err != nil {
			return err
		}
	}
	dir, err := taskPayloadDirectory(input)
	if err != nil {
		return err
	}
	req := &base.Request{URL: input.URL, Extra: &fhttp.ReqExtra{Header: input.Headers, NetworkPolicy: input.NetworkPolicy}, Labels: map[string]string{"asterlinkId": input.ID}}
	if input.OutputKey != "" {
		req.Labels[outputKeyLabel] = input.OutputKey
	}
	if taskID, ok := taskIDs[input.ID]; ok {
		task := core.GetTask(taskID)
		if task != nil {
			if err = core.PauseAndSave(taskID); err != nil {
				return err
			}
			// Android may evict externalCacheDir while the encrypted checkpoint survives.
			// A preallocated range payload must still exist at the original length.
			if name := httpPayloadPath(task, dir); name != "" && outputMatches(task, input) {
				if err = bindOutput(input, name); err != nil {
					return err
				}
			}
			if outputMatches(task, input) && payloadPresent(task, dir) {
				if task.Status == base.DownloadStatusDone {
					remember(&download.Event{Task: task})
					return nil
				}
				req.Labels["asterlinkGeneration"] = task.Meta.Req.Labels["asterlinkGeneration"]
				if err = core.ReplacePausedRequest(taskID, req, input.ConnectionProfile, &fhttp.OptsExtra{Connections: input.Connections, AliyunGroup: input.AliyunGroup}); err != nil {
					return err
				}
				aliyun := task.AliyunTransferState()
				stateMu.Lock()
				progress := states[input.ID]
				progress.Status, progress.Error, progress.HTTPCode = "running", "", 0
				progress.Path = snapshotOutputPath(task, task.Meta.SingleFilepath())
				if input.ConnectionProfile == "aliyun" {
					progress.Aliyun, progress.ActiveConnections = aliyun, 0
					progress.RetryAfterMS, progress.RetryExhausted, progress.ErrorKind = 0, false, ""
				}
				states[input.ID] = progress
				stateMu.Unlock()
				return core.ContinueBatch(&download.TaskFilter{IDs: []string{taskID}})
			}
		}
		if err = removeLocked(input.ID); err != nil {
			return err
		}
	}
	// Legacy Kotlin checkpoints and orphan native payloads cannot be resumed by
	// a new Gopeed task. Only this app-owned task directory is cleared.
	if err = clearTaskPayload(dir); err != nil {
		return err
	}
	if err = bindOutput(input, filepath.Join(dir, "payload.gopeed")); err != nil {
		return err
	}
	var token [16]byte
	if _, err = rand.Read(token[:]); err != nil {
		return err
	}
	req.Labels["asterlinkGeneration"] = hex.EncodeToString(token[:])
	stateMu.Lock()
	generations[input.ID] = req.Labels["asterlinkGeneration"]
	states[input.ID] = snapshot{Status: "running", Path: input.OutputPath}
	stateMu.Unlock()
	retries := input.Retries
	taskID, err := core.CreateDirect(req, &base.Options{Name: "payload.gopeed", Path: dir,
		Extra: &fhttp.OptsExtra{Connections: input.Connections, ConnectionProfile: input.ConnectionProfile, AliyunGroup: input.AliyunGroup,
			RetryLimit: &retries, SpeedLimit: input.SpeedLimit}})
	if err != nil {
		outputfile.Remove(input.ID)
		return err
	}
	taskIDs[input.ID] = taskID
	return nil
}

func payloadPresent(task *download.Task, dir string) bool {
	name := httpPayloadPath(task, dir)
	if name == "" {
		return false
	}
	_, direct := outputfile.Path(name)
	info, err := os.Lstat(name)
	if direct {
		info, err = outputfile.Stat(name)
	} else if task.Meta.Req.Labels[outputKeyLabel] != "" {
		return false
	}
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	return task.Meta.Res.Size <= 0 || info.Size() == task.Meta.Res.Size
}

func httpPayloadPath(task *download.Task, dir string) string {
	if task.Protocol != "http" || task.Meta == nil || task.Meta.Req == nil || task.Meta.Res == nil || task.Meta.Opts == nil || len(task.Meta.Res.Files) != 1 {
		return ""
	}
	name := task.Meta.SingleFilepath()
	if filepath.Clean(filepath.Dir(name)) != filepath.Clean(dir) {
		return ""
	}
	return name
}

func clearTaskPayload(dir string) error {
	root := filepath.Dir(dir)
	if !validPayloadRoot(root) || !safeID.MatchString(filepath.Base(dir)) {
		return errors.New("invalid task cache directory")
	}
	if err := checkTaskPayloadDirectory(root, dir); err != nil {
		return err
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

func Snapshot(id string) (string, error) {
	stateMu.RLock()
	value, ok := states[id]
	stateMu.RUnlock()
	if !ok {
		return "", download.ErrTaskNotFound
	}
	data, err := json.Marshal(value)
	return string(data), err
}

func Pause(id string) error {
	apiMu.Lock()
	defer apiMu.Unlock()
	if core == nil {
		return nil
	}
	taskID, ok := taskIDs[id]
	if !ok {
		return nil
	}
	return core.PauseAndSave(taskID)
}

func Remove(id string) error {
	apiMu.Lock()
	defer apiMu.Unlock()
	return removeLocked(id)
}

func removeLocked(id string) error {
	if core == nil {
		outputfile.Remove(id)
		return nil
	}
	taskID, ok := taskIDs[id]
	if !ok {
		outputfile.Remove(id)
		return nil
	}
	if err := core.PauseAndSave(taskID); err != nil && !errors.Is(err, download.ErrTaskNotFound) {
		return err
	}
	if task := core.GetTask(taskID); task != nil && task.Protocol == "ed2k" && task.Meta.Res != nil {
		if err := ed2kRuntime.Forget(task.Meta.Res.Hash, task.Meta.SingleFilepath()); err != nil {
			return err
		}
	}
	if err := core.Delete(&download.TaskFilter{IDs: []string{taskID}}, false); err != nil {
		return err
	}
	outputfile.Remove(id)
	delete(taskIDs, id)
	stateMu.Lock()
	delete(generations, id)
	delete(states, id)
	stateMu.Unlock()
	return nil
}

func Version() string { return "1.8.1" }

func Close() error {
	closeParserRequests()
	closeHTTPProbes()
	closeTorrentMetadata()
	apiMu.Lock()
	defer apiMu.Unlock()
	closeTorrentStreams()
	stopDiscoverySaver()
	defer btpolicy.Clear()
	if core == nil {
		return nil
	}
	for _, taskID := range taskIDs {
		if err := core.PauseAndSave(taskID); err != nil {
			return err
		}
	}
	if discoveryStorage != nil {
		corebt.RememberDiscovery()
		_ = discoveryStorage.Put("bt-discovery", "nodes", btpolicy.SnapshotDiscovery())
	}
	err := core.Close()
	discoveryStorage = nil
	core = nil
	outputfile.Clear()
	stateMu.Lock()
	generations = map[string]string{}
	states = map[string]snapshot{}
	stateMu.Unlock()
	return err
}
