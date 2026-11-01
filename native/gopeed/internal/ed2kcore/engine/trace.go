package engine

import (
	"encoding/json"
	"log"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/disk"
	"github.com/GopeedLab/gopeed/internal/ed2kcore/transfer"
)

// traceLine is one line of the trace file (docs/protocol.md Trace).
type traceLine map[string]any

func toTraceLine(ev transfer.TraceEvent) traceLine {
	line := traceLine{
		"time":   ev.Time.UnixMilli(),
		"hash":   ev.Hash.String(),
		"source": ev.Source,
		"event":  string(ev.Event),
	}
	switch ev.Event {
	case transfer.EventFound:
		line["channel"] = string(ev.Channel)
	case transfer.EventConnected:
		line["isIpv6"] = ev.IsIPv6
	case transfer.EventFailed, transfer.EventClosed:
		line["reason"] = ev.Reason
	case transfer.EventQueued:
		line["rank"] = ev.Rank
	case transfer.EventReceived:
		line["bytes"] = ev.Bytes
	}
	return line
}

// maxTraceBacklog bounds the lines waiting for a slow trace file; more are
// dropped, since the trace is only a diagnostic.
const maxTraceBacklog = 65536

func (e *Engine) sendTrace(ev transfer.TraceEvent) {
	if e.trace != nil && len(e.trace.backlog) < maxTraceBacklog {
		e.trace.send(toTraceLine(ev))
	}
}

// openTrace opens the trace file for appending at end, so a restarted
// engine adds to the trace of the one before.
func openTrace(d disk.Disk, path string) (file disk.File, end int64, err error) {
	if file, err = d.Open(path, disk.Create); err != nil {
		return nil, 0, err
	}
	info, err := d.Probe(path)
	if err != nil {
		file.Close()
		return nil, 0, err
	}
	return file, info.Size, nil
}

// runTraceWriter is the trace file's leaf; it appends each line and reports
// it written so the hub can send the next.
func (e *Engine) runTraceWriter(file disk.File, end int64, lines <-chan traceLine) {
	defer file.Close()
	isBroken := false
	for {
		select {
		case line := <-lines:
			if !isBroken {
				raw, _ := json.Marshal(line)
				n, err := file.WriteAt(append(raw, '\n'), end)
				end += int64(n)
				if err != nil {
					log.Printf("engine: trace: %v", err)
					isBroken = true
				}
			}
			if !e.send(e.ctx, traceWritten{}) {
				return
			}
		case <-e.ctx.Done():
			return
		}
	}
}
