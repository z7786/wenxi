// AsterLink's desktop control transport. Requests and credentials use inherited
// pipes. BT media alone uses a tokenized loopback HTTP endpoint during playback.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"

	gopeed "github.com/GopeedLab/gopeed/bind/asterlink"
)

type request struct {
	Seq    int64           `json:"seq"`
	Method string          `json:"method"`
	Args   json.RawMessage `json:"args"`
}
type response struct {
	Seq    int64  `json:"seq"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

func handle(input request) (result any, err error) {
	defer func() {
		if recover() != nil {
			result = nil
			err = errors.New("下载组件处理请求失败")
		}
	}()
	var args struct {
		ID         string `json:"id"`
		StorageDir string `json:"storageDir"`
		CacheDir   string `json:"cacheDir"`
		Key        string `json:"key"`
		Path       string `json:"path"`
	}
	if len(input.Args) > 0 && string(input.Args) != "null" {
		if json.Unmarshal(input.Args, &args) != nil {
			return nil, errors.New("下载请求格式错误")
		}
	}
	switch input.Method {
	case "version":
		return map[string]any{"version": gopeed.Version(), "protocol": 1, "taskCacheRoots": true, "sourceNetworkPolicy": true, "parserHttp2": true, "ed2k": true}, nil
	case "freeSpace":
		bytes, err := availableSpace(args.Path)
		return map[string]any{"bytes": bytes}, err
	case "open":
		err = gopeed.Open(args.StorageDir, args.CacheDir, args.Key)
	case "begin":
		err = gopeed.Begin(string(input.Args))
	case "parserRequestStart":
		err = gopeed.StartParserRequest(string(input.Args))
	case "parserRequestStatus":
		var value string
		value, err = gopeed.ParserRequestStatus(args.ID)
		if err == nil {
			err = json.Unmarshal([]byte(value), &result)
		}
	case "parserRequestStop":
		gopeed.StopParserRequest(args.ID)
	case "httpProbeStart":
		err = gopeed.StartHttpProbe(string(input.Args))
	case "httpProbeStatus":
		var value string
		value, err = gopeed.HttpProbeStatus(args.ID)
		if err == nil {
			err = json.Unmarshal([]byte(value), &result)
		}
	case "httpProbeStop":
		gopeed.StopHttpProbe(args.ID)
	case "torrentResolve":
		err = gopeed.ResolveTorrent(string(input.Args))
	case "torrentMetadata":
		var value string
		value, err = gopeed.TorrentMetadata(args.ID)
		if err == nil {
			err = json.Unmarshal([]byte(value), &result)
		}
	case "torrentCancel":
		gopeed.CancelTorrent(args.ID)
	case "torrentStreamStart", "torrentStreamStatus":
		var value string
		if input.Method == "torrentStreamStart" {
			value, err = gopeed.StartTorrentStream(string(input.Args))
		} else {
			value, err = gopeed.TorrentStreamStatus(args.ID)
		}
		if err == nil {
			err = json.Unmarshal([]byte(value), &result)
		}
	case "torrentStreamStop":
		gopeed.StopTorrentStream(args.ID)
	case "torrentStreamInterrupt":
		gopeed.InterruptTorrentStream(args.ID)
	case "snapshot":
		var value string
		value, err = gopeed.Snapshot(args.ID)
		if err == nil {
			err = json.Unmarshal([]byte(value), &result)
		}
	case "pause":
		err = gopeed.Pause(args.ID)
	case "remove":
		err = gopeed.Remove(args.ID)
	case "close":
		err = gopeed.Close()
	default:
		err = errors.New("未知下载组件请求")
	}
	return result, err
}

func serve(in io.Reader, out io.Writer) error {
	defer gopeed.Close()
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 4096), 8*1024*1024)
	encoder := json.NewEncoder(out)
	for scanner.Scan() {
		var input request
		if json.Unmarshal(scanner.Bytes(), &input) != nil {
			return errors.New("invalid protocol frame")
		}
		result, err := handle(input)
		output := response{Seq: input.Seq, Result: result}
		if err != nil {
			// Low-level errors may contain signed URLs or local paths. Progress errors
			// are already sanitized by the core; transport failures stay generic.
			output.Error = "下载组件操作失败，请重试并检查下载目录"
		}
		if err := encoder.Encode(output); err != nil {
			return err
		}
		if input.Method == "close" {
			return nil
		}
	}
	return scanner.Err()
}

func main() {
	if serve(os.Stdin, os.Stdout) != nil {
		os.Exit(1)
	}
}
