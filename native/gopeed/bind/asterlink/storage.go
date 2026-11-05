package gopeed

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/json"
	"errors"
	"go.etcd.io/bbolt"
	"os"
	"path/filepath"
	"time"
)

// Keep the legacy cipher only for migration. All new values are plain JSON.
type encryptedStorage struct {
	db  *bbolt.DB
	box cipher.AEAD
}

func newEncryptedStorage(dir string, key []byte) (*encryptedStorage, error) {
	var box cipher.AEAD
	if len(key) == 32 {
		block, err := aes.NewCipher(key)
		if err != nil {
			return nil, err
		}
		box, err = cipher.NewGCM(block)
		if err != nil {
			return nil, err
		}
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	db, err := bbolt.Open(filepath.Join(dir, "gopeed.db"), 0600, &bbolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	storage := &encryptedStorage{db, box}
	// One transaction converts every bucket and publishes the format marker.
	// A missing/wrong old key rolls back all changes, including checkpoints.
	err = db.Update(func(tx *bbolt.Tx) error {
		if meta := tx.Bucket([]byte("asterlink-storage-format")); meta != nil {
			version := string(meta.Get([]byte("version")))
			if version == "2" {
				return nil
			}
			if version != "" {
				return errors.New("unsupported download storage format")
			}
		}
		if err := tx.ForEach(func(name []byte, bucket *bbolt.Bucket) error {
			updates := map[string][]byte{}
			if err := bucket.ForEach(func(id, data []byte) error {
				if data == nil || json.Valid(data) {
					return nil
				}
				var value json.RawMessage
				if err := storage.decode(string(name), string(id), data, &value); err != nil {
					return err
				}
				updates[string(id)] = append([]byte(nil), value...)
				return nil
			}); err != nil {
				return err
			}
			for id, data := range updates {
				if err := bucket.Put([]byte(id), data); err != nil {
					return err
				}
			}
			return nil
		}); err != nil {
			return err
		}
		meta, err := tx.CreateBucketIfNotExists([]byte("asterlink-storage-format"))
		if err != nil {
			return err
		}
		return meta.Put([]byte("version"), []byte("2"))
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	storage.box = nil
	return storage, nil
}
func (s *encryptedStorage) Setup(names []string) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		for _, name := range names {
			if _, err := tx.CreateBucketIfNotExists([]byte(name)); err != nil {
				return err
			}
		}
		return nil
	})
}
func (s *encryptedStorage) decode(bucket, key string, data []byte, out any) error {
	if json.Valid(data) {
		return json.Unmarshal(data, out)
	}
	if s.box == nil {
		return errors.New("legacy download state needs its original key")
	}
	if len(data) < s.box.NonceSize()+s.box.Overhead() {
		return errors.New("invalid encrypted download state")
	}
	plain, err := s.box.Open(nil, data[:s.box.NonceSize()], data[s.box.NonceSize():], []byte(bucket+"\x00"+key))
	if err != nil {
		return errors.New("cannot decrypt download state")
	}
	return json.Unmarshal(plain, out)
}
func (s *encryptedStorage) Put(bucket, key string, value any) error {
	plain, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return s.db.Update(func(tx *bbolt.Tx) error { return tx.Bucket([]byte(bucket)).Put([]byte(key), plain) })
}
func (s *encryptedStorage) Get(bucket, key string, out any) (found bool, err error) {
	err = s.db.View(func(tx *bbolt.Tx) error {
		data := tx.Bucket([]byte(bucket)).Get([]byte(key))
		if data == nil {
			return nil
		}
		found = true
		return s.decode(bucket, key, data, out)
	})
	return
}
func (s *encryptedStorage) List(bucket string, out any) error {
	values := make([]json.RawMessage, 0)
	err := s.db.View(func(tx *bbolt.Tx) error {
		return tx.Bucket([]byte(bucket)).ForEach(func(key, data []byte) error {
			var value json.RawMessage
			if err := s.decode(bucket, string(key), data, &value); err != nil {
				return err
			}
			values = append(values, value)
			return nil
		})
	})
	if err != nil {
		return err
	}
	data, err := json.Marshal(values)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, out)
}
func (s *encryptedStorage) Pop(bucket, key string, out any) error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		b := tx.Bucket([]byte(bucket))
		data := b.Get([]byte(key))
		if data == nil {
			return nil
		}
		if err := s.decode(bucket, key, data, out); err != nil {
			return err
		}
		// Retain the last durable checkpoint until a newer one replaces it. A process
		// killed immediately after resume must still have its saved range positions.
		return nil
	})
}
func (s *encryptedStorage) Delete(bucket, key string) error {
	return s.db.Update(func(tx *bbolt.Tx) error { return tx.Bucket([]byte(bucket)).Delete([]byte(key)) })
}
func (s *encryptedStorage) Clear() error {
	return s.db.Update(func(tx *bbolt.Tx) error {
		var names [][]byte
		if err := tx.ForEach(func(name []byte, _ *bbolt.Bucket) error {
			if string(name) == "asterlink-storage-format" {
				return nil
			}
			names = append(names, append([]byte(nil), name...))
			return nil
		}); err != nil {
			return err
		}
		for _, name := range names {
			if err := tx.DeleteBucket(name); err != nil {
				return err
			}
			if _, err := tx.CreateBucket(name); err != nil {
				return err
			}
		}
		return nil
	})
}
func (s *encryptedStorage) Close() error { return s.db.Close() }

// StorageFormat lets the Android bridge bypass old key storage after migration.
func StorageFormat(dir string) string {
	path := filepath.Join(dir, "gopeed.db")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return "plain"
	}
	db, err := bbolt.Open(path, 0600, &bbolt.Options{ReadOnly: true, Timeout: time.Second})
	if err != nil {
		return "legacy"
	}
	defer db.Close()
	plain := false
	db.View(func(tx *bbolt.Tx) error {
		meta := tx.Bucket([]byte("asterlink-storage-format"))
		plain = meta != nil && string(meta.Get([]byte("version"))) == "2"
		return nil
	})
	if plain {
		return "plain"
	}
	return "legacy"
}
