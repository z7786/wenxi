//go:build !windows

package transport

func isWindowsRefused(error) bool { return false }
