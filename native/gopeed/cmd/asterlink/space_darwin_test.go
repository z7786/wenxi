package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAvailableSpaceForNewDownloadDirectory(t *testing.T) {
	directory := t.TempDir()
	for _, path := range []string{directory, filepath.Join(directory, "new", "downloads")} {
		bytes, err := availableSpace(path)
		if err != nil || bytes == 0 {
			t.Fatalf("availableSpace(%q) = %d, %v", path, bytes, err)
		}
	}
	if _, err := os.Stat(filepath.Join(directory, "new")); !os.IsNotExist(err) {
		t.Fatal("checking capacity must not create a download directory")
	}
}

func TestAvailableSpaceRejectsInvalidPath(t *testing.T) {
	if _, err := availableSpace("invalid\x00path"); err == nil {
		t.Fatal("invalid paths must report an error")
	}
}
