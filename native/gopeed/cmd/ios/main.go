// iOS cannot launch the desktop helper. Its C ABI keeps the core in-process.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"unsafe"

	gopeed "github.com/GopeedLab/gopeed/bind/asterlink"
)

func dispatch(method, encoded string) (result any, err error) {
	defer func() {
		if recover() != nil {
			result = nil
			err = errors.New("download request failed")
		}
	}()
	var args struct {
		ID         string `json:"id"`
		StorageDir string `json:"storageDir"`
		CacheDir   string `json:"cacheDir"`
		Key        string `json:"key"`
	}
	if err = json.Unmarshal([]byte(encoded), &args); err != nil {
		return
	}
	var value string
	switch method {
	case "version":
		result = map[string]any{"version": gopeed.Version(), "protocol": 1, "taskCacheRoots": true, "sourceNetworkPolicy": true, "parserHttp2": true, "ed2k": true}
	case "open":
		err = gopeed.Open(args.StorageDir, args.CacheDir, args.Key)
	case "begin":
		err = gopeed.Begin(encoded)
	case "snapshot":
		value, err = gopeed.Snapshot(args.ID)
	case "pause":
		err = gopeed.Pause(args.ID)
	case "remove":
		err = gopeed.Remove(args.ID)
	case "close":
		err = gopeed.Close()
	case "parserRequestStart":
		err = gopeed.StartParserRequest(encoded)
	case "parserRequestStatus":
		value, err = gopeed.ParserRequestStatus(args.ID)
	case "parserRequestStop":
		gopeed.StopParserRequest(args.ID)
	case "httpProbeStart":
		err = gopeed.StartHttpProbe(encoded)
	case "httpProbeStatus":
		value, err = gopeed.HttpProbeStatus(args.ID)
	case "httpProbeStop":
		gopeed.StopHttpProbe(args.ID)
	case "torrentResolve":
		err = gopeed.ResolveTorrent(encoded)
	case "torrentMetadata":
		value, err = gopeed.TorrentMetadata(args.ID)
	case "torrentCancel":
		gopeed.CancelTorrent(args.ID)
	case "torrentStreamStart":
		value, err = gopeed.StartTorrentStream(encoded)
	case "torrentStreamStatus":
		value, err = gopeed.TorrentStreamStatus(args.ID)
	case "torrentStreamStop":
		gopeed.StopTorrentStream(args.ID)
	case "torrentStreamInterrupt":
		gopeed.InterruptTorrentStream(args.ID)
	default:
		err = errors.New("unknown download request")
	}
	if err == nil && value != "" {
		err = json.Unmarshal([]byte(value), &result)
	}
	return
}

//export AsterLinkCall
func AsterLinkCall(method, encoded *C.char) *C.char {
	result, err := dispatch(C.GoString(method), C.GoString(encoded))
	response := map[string]any{"result": result}
	if err != nil {
		response = map[string]any{"error": "下载组件操作失败，请重试并检查下载目录"}
	}
	data, _ := json.Marshal(response)
	return C.CString(string(data))
}

//export AsterLinkFree
func AsterLinkFree(value *C.char) { C.free(unsafe.Pointer(value)) }

func main() {}
