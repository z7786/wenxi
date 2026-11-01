package transport

import (
	"errors"
	"syscall"
)

// Winsock reports a refused or timed-out connect with its own codes;
// syscall.ECONNREFUSED and ETIMEDOUT there are invented values that it
// never returns.
const (
	wsaeTimedOut    syscall.Errno = 10060
	wsaeConnRefused syscall.Errno = 10061
)

func isWindowsRefused(err error) bool {
	return errors.Is(err, wsaeConnRefused) || errors.Is(err, wsaeTimedOut)
}
