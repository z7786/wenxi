package gopeed

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/json"
	"path/filepath"
	"testing"

	"go.etcd.io/bbolt"
)

func legacyStorageFixture(t *testing.T, dir string, key []byte) map[string][]byte {
	t.Helper()
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	box, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	db, err := bbolt.Open(filepath.Join(dir, "gopeed.db"), 0600, nil)
	if err != nil {
		t.Fatal(err)
	}
	original := map[string][]byte{}
	err = db.Update(func(tx *bbolt.Tx) error {
		for _, bucket := range []string{"task", "fetcher", "ed2k", "bt_discovery"} {
			b, createErr := tx.CreateBucket([]byte(bucket))
			if createErr != nil {
				return createErr
			}
			plain, _ := json.Marshal(map[string]any{"id": "kept", "done": 7654321, "ranges": []int{0, 1024, 4096}, "cookie": "fixture-only"})
			nonce := bytes.Repeat([]byte{byte(len(bucket))}, box.NonceSize())
			encrypted := append(nonce, box.Seal(nil, nonce, plain, []byte(bucket+"\x00kept"))...)
			original[bucket] = append([]byte(nil), encrypted...)
			if putErr := b.Put([]byte("kept"), encrypted); putErr != nil {
				return putErr
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}
	return original
}

func TestLegacyStorageMigrationIsAtomicAndKeepsAllCheckpoints(t *testing.T) {
	dir, key := t.TempDir(), bytes.Repeat([]byte{23}, 32)
	original := legacyStorageFixture(t, dir, key)
	if StorageFormat(dir) != "legacy" {
		t.Fatal("old storage not identified")
	}
	for _, wrong := range [][]byte{nil, bytes.Repeat([]byte{24}, 32)} {
		store, err := newEncryptedStorage(dir, wrong)
		if err == nil {
			store.Close()
			t.Fatal("wrong legacy key accepted")
		}
		db, openErr := bbolt.Open(filepath.Join(dir, "gopeed.db"), 0600, nil)
		if openErr != nil {
			t.Fatal(openErr)
		}
		db.View(func(tx *bbolt.Tx) error {
			if tx.Bucket([]byte("asterlink-storage-format")) != nil {
				t.Fatal("migration marker committed on failure")
			}
			for bucket, before := range original {
				if !bytes.Equal(tx.Bucket([]byte(bucket)).Get([]byte("kept")), before) {
					t.Fatal("legacy checkpoint changed on failure")
				}
			}
			return nil
		})
		db.Close()
	}
	store, err := newEncryptedStorage(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	if store.box != nil {
		t.Fatal("old cipher retained after migration")
	}
	for bucket := range original {
		var value map[string]any
		if found, readErr := store.Get(bucket, "kept", &value); readErr != nil || !found || value["done"] != float64(7654321) {
			t.Fatalf("checkpoint missing: %s %v %v", bucket, value, readErr)
		}
		var popped map[string]any
		if err = store.Pop(bucket, "kept", &popped); err != nil {
			t.Fatal(err)
		}
		if found, _ := store.Get(bucket, "kept", &value); !found {
			t.Fatal("resume consumed the durable checkpoint")
		}
	}
	store.Close()
	if StorageFormat(dir) != "plain" {
		t.Fatal("new storage not identified")
	}
	reopened, err := newEncryptedStorage(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	var values []map[string]any
	if err = reopened.List("fetcher", &values); err != nil || len(values) != 1 || values[0]["cookie"] != "fixture-only" {
		t.Fatalf("reopen lost state: %v %v", values, err)
	}
}

func TestCorruptLegacyCheckpointDoesNotPartiallyMigrate(t *testing.T) {
	dir, key := t.TempDir(), bytes.Repeat([]byte{1}, 32)
	original := legacyStorageFixture(t, dir, key)
	db, err := bbolt.Open(filepath.Join(dir, "gopeed.db"), 0600, nil)
	if err != nil {
		t.Fatal(err)
	}
	db.Update(func(tx *bbolt.Tx) error { return tx.Bucket([]byte("task")).Put([]byte("kept"), []byte("broken")) })
	db.Close()
	if store, err := newEncryptedStorage(dir, key); err == nil {
		store.Close()
		t.Fatal("corrupt checkpoint ignored")
	}
	db, err = bbolt.Open(filepath.Join(dir, "gopeed.db"), 0600, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.View(func(tx *bbolt.Tx) error {
		if !bytes.Equal(tx.Bucket([]byte("fetcher")).Get([]byte("kept")), original["fetcher"]) {
			t.Fatal("other bucket was partially migrated")
		}
		return nil
	})
}

func TestPlainStorageClearPreservesFormatAndNeedsNoKey(t *testing.T) {
	dir := t.TempDir()
	store, err := newEncryptedStorage(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = store.Setup([]string{"task", "fetcher"}); err != nil {
		t.Fatal(err)
	}
	if err = store.Put("task", "id", map[string]int{"done": 123}); err != nil {
		t.Fatal(err)
	}
	if err = store.Clear(); err != nil {
		t.Fatal(err)
	}
	var value map[string]int
	if found, readErr := store.Get("task", "id", &value); readErr != nil || found {
		t.Fatalf("clear retained a task: %v %v", found, readErr)
	}
	store.Close()
	if StorageFormat(dir) != "plain" {
		t.Fatal("clear lost the plain format marker")
	}
	reopened, err := newEncryptedStorage(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	reopened.Close()
}

func TestFutureStorageFormatIsRetainedAndRejected(t *testing.T) {
	dir := t.TempDir()
	db, err := bbolt.Open(filepath.Join(dir, "gopeed.db"), 0600, nil)
	if err != nil {
		t.Fatal(err)
	}
	db.Update(func(tx *bbolt.Tx) error {
		meta, createErr := tx.CreateBucket([]byte("asterlink-storage-format"))
		if createErr != nil {
			return createErr
		}
		return meta.Put([]byte("version"), []byte("3"))
	})
	db.Close()
	if store, openErr := newEncryptedStorage(dir, nil); openErr == nil {
		store.Close()
		t.Fatal("future download state silently downgraded")
	}
	db, err = bbolt.Open(filepath.Join(dir, "gopeed.db"), 0600, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.View(func(tx *bbolt.Tx) error {
		if string(tx.Bucket([]byte("asterlink-storage-format")).Get([]byte("version"))) != "3" {
			t.Fatal("future version marker changed")
		}
		return nil
	})
}
