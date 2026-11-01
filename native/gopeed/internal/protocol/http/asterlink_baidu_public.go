package http

import fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"

func connectionLimit(extra *fhttp.OptsExtra) int {
	if extra.ConnectionProfile == "baidu_public" || extra.ConnectionProfile == "baidu" || extra.ConnectionProfile == "baidu_preview" {
		return max(1, min(512, extra.Connections))
	}
	return fhttp.BaiduConnectionLimit(extra.ConnectionProfile)
}

// Called while paused. Split only unread tails so old single-connection Baidu
// downloads can use their new setting without discarding checkpointed bytes.
func (f *Fetcher) expandPublicConnections() {
	extra := f.meta.Opts.Extra.(*fhttp.OptsExtra)
	if (extra.ConnectionProfile != "baidu_public" && extra.ConnectionProfile != "baidu" && extra.ConnectionProfile != "baidu_preview" && extra.ConnectionProfile != "baidu_direct") || !f.meta.Res.Range {
		return
	}
	target := effectiveConnections(f.meta.Res.Size, extra.Connections, extra.ConnectionProfile)
	for len(f.connections) < target {
		var largest *connection
		var remaining int64
		for _, candidate := range f.connections {
			candidate.mu.RLock()
			size := candidate.Chunk.remain()
			candidate.mu.RUnlock()
			if size > remaining {
				largest, remaining = candidate, size
			}
		}
		if largest == nil || remaining < 2*minRangeSize {
			return
		}
		largest.mu.Lock()
		first := largest.Chunk.Begin + largest.Chunk.Downloaded
		middle := first + remaining/2
		end := largest.Chunk.End
		largest.Chunk.End = middle - 1
		largest.mu.Unlock()
		f.connections = append(f.connections, &connection{Chunk: newChunk(middle, end)})
	}
}
