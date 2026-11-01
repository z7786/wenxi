package ed2k

import (
	"golang.org/x/sys/windows"
	"os"
)

// ED2K peers send parts out of order. Avoid zero-filling a large Windows
// prefix before the first distant write; unsupported filesystems fall back.
func prepareOutput(file *os.File) {
	var returned uint32
	_ = windows.DeviceIoControl(windows.Handle(file.Fd()), windows.FSCTL_SET_SPARSE,
		nil, 0, nil, 0, &returned, nil)
}
