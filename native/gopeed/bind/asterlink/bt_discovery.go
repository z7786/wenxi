package gopeed

import (
	"github.com/GopeedLab/gopeed/internal/btpolicy"
	corebt "github.com/GopeedLab/gopeed/internal/protocol/bt"
	"time"
)

var discoveryStop, discoveryDone chan struct{}
var discoveryStorage *encryptedStorage

func startDiscoverySaver(storage *encryptedStorage) {
	discoveryStorage = storage
	var saved btpolicy.Discovery
	if found, err := storage.Get("bt-discovery", "nodes", &saved); err == nil && found {
		btpolicy.Load(saved)
	}
	discoveryStop, discoveryDone = make(chan struct{}), make(chan struct{})
	go func(stop, done chan struct{}) {
		defer close(done)
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				corebt.RememberDiscovery()
				_ = storage.Put("bt-discovery", "nodes", btpolicy.SnapshotDiscovery())
			}
		}
	}(discoveryStop, discoveryDone)
}

func stopDiscoverySaver() {
	if discoveryStop != nil {
		close(discoveryStop)
		<-discoveryDone
		discoveryStop, discoveryDone = nil, nil
	}
}
