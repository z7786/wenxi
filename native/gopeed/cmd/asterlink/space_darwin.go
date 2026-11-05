package main

import (
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
)

func availableSpace(path string) (uint64, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return 0, err
	}
	for {
		if _, err := os.Stat(absolute); err == nil {
			break
		} else if !os.IsNotExist(err) {
			return 0, err
		}
		parent := filepath.Dir(absolute)
		if parent == absolute {
			return 0, os.ErrNotExist
		}
		absolute = parent
	}
	var stat unix.Statfs_t
	if err := unix.Statfs(absolute, &stat); err != nil {
		return 0, err
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), nil
}
