//go:build !windows

package ed2k

import "os"

func prepareOutput(*os.File) {}
