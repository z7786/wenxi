package kad

import (
	"net/netip"

	"github.com/GopeedLab/gopeed/internal/ed2kcore/wire"
)

// FirewallCheck asks the engine to connect to a node that wants to know
// whether its TCP port is open, and to tell it once the handshake is done:
// over TCP for Kad version 7 and up, or by posting a FirewallAck to
// KadPort.
type FirewallCheck struct {
	// Addr is the node's IP and TCP port.
	Addr         netip.AddrPort
	KadPort      uint16
	UserHash     wire.Hash
	CryptOptions byte
}

// UDPCheck asks the engine to connect to a client and, after the handshake,
// send it OP_FWCHECKUDPREQ with our Kad ports and Key, so that it sends UDP
// test packets to them. The engine posts UDPCheckEnded when the connection
// closes; the answer itself reaches Kad over UDP.
type UDPCheck struct {
	Addr       netip.AddrPort
	InternPort uint16
	ExternPort uint16
	Key        uint32
}

func (FirewallCheck) isEvent() {}
func (UDPCheck) isEvent()      {}

// FirewallUDP is a client's request, over TCP, to send it UDP test packets
// to its Kad ports InternPort and ExternPort.
type FirewallUDP struct {
	IP         netip.Addr
	InternPort uint16
	ExternPort uint16
	Key        uint32
	// IsKnown: the engine already exchanges files with IP, so a test packet
	// reaching it proves nothing.
	IsKnown bool
}

// UDPCheckEnded reports that the connection for a UDPCheck to IP closed.
// IsCancelled: the check never started (no connection, no handshake, or a
// client that cannot test), so it counts neither way.
type UDPCheckEnded struct {
	IP          netip.Addr
	IsCancelled bool
}

// FirewallAckReceived is an OP_KAD_FWTCPCHECK_ACK the engine received
// over TCP from From.
type FirewallAckReceived struct{ From netip.Addr }

// FirewallAck asks Kad to send KADEMLIA_FIREWALLED_ACK_RES to the Kad
// endpoint To of a node older than Kad version 7 whose TCP port we reached.
type FirewallAck struct{ To netip.AddrPort }

func (FirewallUDP) isMessage()         {}
func (UDPCheckEnded) isMessage()       {}
func (FirewallAckReceived) isMessage() {}
func (FirewallAck) isMessage()         {}
