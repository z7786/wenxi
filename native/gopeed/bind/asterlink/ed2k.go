package gopeed

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"path/filepath"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/link"
	"github.com/GopeedLab/gopeed/internal/outputfile"
	coreed2k "github.com/GopeedLab/gopeed/internal/protocol/ed2k"
	"github.com/GopeedLab/gopeed/pkg/base"
	"github.com/GopeedLab/gopeed/pkg/download"
)

// ED2K links are never sent to an HTTP resolver or proxy. The hash and size
// identify the payload; the engine verifies every received eMule part.
func beginEd2k(input request) error {
	file, err := link.Parse(input.URL)
	if err != nil {
		return errors.New("ED2K 文件链接无效")
	}
	if input.NetworkPolicy != nil || len(input.Headers) != 0 {
		return errors.New("ED2K 不支持 HTTP 请求头或来源网络权限")
	}
	for id, taskID := range taskIDs {
		task := core.GetTask(taskID)
		if id != input.ID && task != nil && task.Protocol == "ed2k" && task.Status != base.DownloadStatusDone && task.Meta.Res != nil && task.Meta.Res.Hash == file.Hash.String() {
			return errors.New("相同 ED2K 文件已有下载任务，请继续原任务")
		}
	}
	dir, err := taskPayloadDirectory(input)
	if err != nil {
		return err
	}
	logical := filepath.Join(dir, "payload.gopeed")
	if taskID, ok := taskIDs[input.ID]; ok {
		task := core.GetTask(taskID)
		if task != nil {
			if err = core.PauseAndSave(taskID); err != nil {
				return err
			}
			if task.Protocol == "ed2k" && outputMatches(task, input) && task.Meta.Res != nil &&
				task.Meta.Res.Hash == file.Hash.String() && task.Meta.Res.Size == file.Size &&
				filepath.Clean(task.Meta.SingleFilepath()) == logical {
				if err = bindOutput(input, logical); err != nil {
					return err
				}
				info, statErr := outputfile.Stat(logical)
				resume := false
				if statErr == nil && info.Mode().IsRegular() && info.Size() <= file.Size {
					resume, err = ed2kRuntime.HasResume(file.Hash.String(), logical, file.Size, info.Size())
					if err != nil {
						return err
					}
				}
				if resume {
					if task.Status == base.DownloadStatusDone && info.Size() == file.Size {
						remember(&download.Event{Task: task})
						return nil
					}
					stateMu.Lock()
					value := states[input.ID]
					value.Status, value.Error, value.Speed = "running", "", 0
					value.Path = snapshotOutputPath(task, logical)
					states[input.ID] = value
					stateMu.Unlock()
					return core.ContinueBatch(&download.TaskFilter{IDs: []string{taskID}})
				}
			}
		}
		if err = removeLocked(input.ID); err != nil {
			return err
		}
	}
	// The shared eMule network has one aggregate rate limiter. Keep ED2K
	// payloads serial so the selected per-task limit always applies correctly.
	for id, taskID := range taskIDs {
		task := core.GetTask(taskID)
		if id != input.ID && task != nil && task.Protocol == "ed2k" && task.Status != base.DownloadStatusPause && task.Status != base.DownloadStatusDone {
			return errors.New("ED2K tasks must be scheduled serially")
		}
	}
	if err = clearTaskPayload(dir); err != nil {
		return err
	}
	if err = bindOutput(input, logical); err != nil {
		return err
	}
	// An empty granted target is enough. Kelpie extends it as blocks arrive;
	// preallocation without matching resume state would be an existing file.
	if err = outputfile.Reset(logical, 0); err != nil {
		return err
	}
	var token [16]byte
	if _, err = rand.Read(token[:]); err != nil {
		return err
	}
	req := &base.Request{URL: input.URL, Labels: map[string]string{"asterlinkId": input.ID, "asterlinkGeneration": hex.EncodeToString(token[:])}}
	if input.OutputKey != "" {
		req.Labels[outputKeyLabel] = input.OutputKey
	}
	stateMu.Lock()
	generations[input.ID] = req.Labels["asterlinkGeneration"]
	states[input.ID] = snapshot{Status: "running", Total: file.Size, Path: input.OutputPath}
	stateMu.Unlock()
	taskID, err := core.CreateDirect(req, &base.Options{Name: "payload.gopeed", Path: dir, Extra: &coreed2k.Options{SpeedLimit: input.SpeedLimit}})
	if err != nil {
		outputfile.Remove(input.ID)
		return err
	}
	taskIDs[input.ID] = taskID
	return nil
}
