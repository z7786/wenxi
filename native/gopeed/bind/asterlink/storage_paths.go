package gopeed

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	ed2kstore "github.com/GopeedLab/gopeed/internal/ed2kcore/store"
	"go.etcd.io/bbolt"
)

var appleContainerPath = regexp.MustCompile(`^(/(?:private/)?var/mobile/Containers/Data/Application/[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})(?:/(?:Documents|Library|tmp)(?:/|$)|$)`)

func relocatedStoragePath(original string, paths map[string]string, home string) string {
	prefixes := make([]string, 0, len(paths))
	for path, replacement := range paths {
		if (filepath.IsAbs(path) || strings.HasPrefix(path, "/")) && (filepath.IsAbs(replacement) || strings.HasPrefix(replacement, "/")) {
			prefixes = append(prefixes, path)
		}
	}
	sort.Slice(prefixes, func(i, j int) bool { return len(prefixes[i]) > len(prefixes[j]) })
	value, visited := original, map[string]bool{}
	for step := 0; step < len(prefixes); step++ {
		visited[value] = true
		next := value
		for _, prefix := range prefixes {
			if value == prefix || strings.HasPrefix(value, prefix+"/") || strings.HasPrefix(value, prefix+string(filepath.Separator)) {
				next = paths[prefix] + value[len(prefix):]
				break
			}
		}
		if next == value {
			break
		}
		if visited[next] {
			return original
		}
		value = next
	}
	// First adapted builds have no previous-home marker. Only app-container
	// paths in known storage fields qualify; URLs and credentials are excluded.
	current := appleContainerPath.FindStringSubmatch(home)
	old := appleContainerPath.FindStringSubmatch(value)
	if len(current) > 1 && current[1] == home && len(old) > 1 && old[1] != home {
		value = home + value[len(old[1]):]
	}
	return value
}

func storageObject(value any) map[string]any {
	object, _ := value.(map[string]any)
	return object
}

// Only known local storage fields are migrated in one transaction. Headers,
// direct links, task identities and saved range checkpoints keep their values.
func (s *encryptedStorage) restorePaths(paths map[string]string, home string) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		for _, name := range []string{"task", "config", "ed2k"} {
			bucket := tx.Bucket([]byte(name))
			if bucket == nil {
				continue
			}
			updates := map[string][]byte{}
			err := bucket.ForEach(func(key, raw []byte) error {
				if raw == nil {
					return nil
				}
				changed := false
				var encoded []byte
				if name == "ed2k" {
					if string(key) != "state" {
						return nil
					}
					var data []byte
					if err := json.Unmarshal(raw, &data); err != nil {
						return err
					}
					state, err := ed2kstore.Decode(data)
					if err != nil {
						return err
					}
					for hash, transfer := range state.Transfers {
						path := relocatedStoragePath(transfer.File, paths, home)
						if path != transfer.File {
							transfer.File = path
							state.Transfers[hash] = transfer
							changed = true
						}
					}
					if !changed {
						return nil
					}
					data, err = ed2kstore.Encode(state)
					if err != nil {
						return err
					}
					encoded, err = json.Marshal(data)
					if err != nil {
						return err
					}
				} else {
					decoder := json.NewDecoder(bytes.NewReader(raw))
					decoder.UseNumber()
					var value map[string]any
					if err := decoder.Decode(&value); err != nil {
						return err
					}
					path := func(object map[string]any, field string) {
						old, ok := object[field].(string)
						if !ok {
							return
						}
						if current := relocatedStoragePath(old, paths, home); current != old {
							object[field], changed = current, true
						}
					}
					if name == "task" {
						meta := storageObject(value["meta"])
						path(storageObject(meta["opts"]), "path")
						req := storageObject(meta["req"])
						path(storageObject(req["labels"]), "asterlinkBTPath")
					} else if string(key) == "config" {
						path(value, "downloadDir")
					}
					if !changed {
						return nil
					}
					var err error
					encoded, err = json.Marshal(value)
					if err != nil {
						return err
					}
				}
				updates[string(key)] = encoded
				return nil
			})
			if err != nil {
				return err
			}
			for key, raw := range updates {
				if err := bucket.Put([]byte(key), raw); err != nil {
					return err
				}
			}
		}
		return nil
	})
}
