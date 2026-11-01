package engine

import (
	"log"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/transport"
)

// setProxy makes transport follow url: the seam itself when url is "", or
// the Proxy over it.
func (e *Engine) setProxy(url string) error {
	if url == "" {
		e.transport, e.proxy, e.proxyIssue, e.proxyIssues = e.ports.Transport, "", "", nil
		return nil
	}
	issues := make(chan string, 1)
	t, err := transport.Proxied(e.ports.Transport, url, func(issue string) { setLatest(issues, issue) })
	if err != nil {
		return toStartFailed(err)
	}
	e.transport, e.proxy, e.proxyIssue, e.proxyIssues = t, url, "", issues
	return nil
}

// moveToProxy follows a changed Proxy. Open TCP connections keep their
// path; UDP moves at once, so nothing goes out directly once a Proxy is set
// (ADR-0006). Kad stops here, leaving the eD2k UDP socket to the engine, and
// update starts it again on the new path.
func (e *Engine) moveToProxy(url string) {
	if err := e.setProxy(url); err != nil {
		log.Printf("engine: proxy: %v", err)
		return
	}
	if e.kad != nil {
		e.stopKad()
	}
	if e.udp != nil {
		e.udp.Close()
		e.udp = nil
	}
	if udp, err := e.buildUDPTransport(false).OpenUDP(e.udpPort); err != nil {
		log.Printf("engine: udp: %v", err)
	} else {
		e.udp = udp
		e.startLeaf(func() { e.runUDPReader(udp, false) })
	}
	serverUDP, err := e.buildUDPTransport(true).OpenUDP(0)
	if err != nil {
		log.Printf("engine: server udp: %v", err)
		return
	}
	e.serverUDP.Close()
	e.serverUDP = serverUDP
	e.startLeaf(func() { e.runUDPReader(serverUDP, true) })
}

// setLatest replaces the value waiting in a latest-value slot.
func setLatest[T any](slot chan T, v T) {
	for {
		select {
		case slot <- v:
			return
		default:
		}
		select {
		case <-slot:
		default:
		}
	}
}
