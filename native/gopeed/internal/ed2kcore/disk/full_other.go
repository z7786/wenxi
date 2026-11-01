//go:build !windows

package disk

func isWindowsFull(error) bool { return false }
