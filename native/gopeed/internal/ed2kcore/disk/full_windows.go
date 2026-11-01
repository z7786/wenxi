package disk

import (
	"errors"
	"syscall"
)

// Windows reports a full disk with its own codes; syscall.ENOSPC there is an
// invented value that the file APIs never return.
const (
	errorHandleDiskFull syscall.Errno = 39
	errorDiskFull       syscall.Errno = 112
)

func isWindowsFull(err error) bool {
	return errors.Is(err, errorDiskFull) || errors.Is(err, errorHandleDiskFull)
}
