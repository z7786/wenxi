package disk

import (
	"io"
	"io/fs"
	"sync"
	"syscall"
)

// Fake is an in-memory Disk whose operations can be made to fail.
type Fake struct {
	// mu guards the files: disk workers and the test touch them at once.
	mu     sync.Mutex
	files  map[string]*fakeData
	faults []*fault
}

type Op int

const (
	OpOpen Op = iota
	OpRead
	OpWrite
	OpSync
)

type fault struct {
	path      string
	op        Op
	err       error
	remaining int
}

type fakeData struct {
	bytes []byte
}

func BuildFake() *Fake {
	return &Fake{files: map[string]*fakeData{}}
}

// AddFault makes the next count operations op on path fail with err, wrapped
// in *fs.PathError as package os does. An empty path matches every path.
// Inject syscall.ENOSPC for a full disk, syscall.EIO for a failing device,
// fs.ErrPermission or fs.ErrNotExist for OpOpen.
func (f *Fake) AddFault(path string, op Op, err error, count int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.faults = append(f.faults, &fault{path: path, op: op, err: err, remaining: count})
}

func (f *Fake) SetData(path string, data []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.files[path] = &fakeData{bytes: append([]byte(nil), data...)}
}

func (f *Fake) DataByPath(path string) ([]byte, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	data, ok := f.files[path]
	if !ok {
		return nil, false
	}
	return append([]byte(nil), data.bytes...), true
}

func (f *Fake) Open(name string, mode Mode) (File, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.matchFault(name, OpOpen, "open"); err != nil {
		return nil, err
	}
	data, ok := f.files[name]
	if !ok && mode != Create {
		return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
	}
	if !ok {
		data = &fakeData{}
		f.files[name] = data
	}
	return &fakeFile{disk: f, name: name, data: data, canWrite: mode != Read}, nil
}

func (f *Fake) Probe(name string) (*Info, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	data, ok := f.files[name]
	if !ok {
		return nil, nil
	}
	return &Info{Size: int64(len(data.bytes))}, nil
}

// matchFault consumes one occurrence of the first fault matching name and op.
// It is called with f.mu held.
func (f *Fake) matchFault(name string, op Op, opName string) error {
	for i, fault := range f.faults {
		if fault.op != op || (fault.path != "" && fault.path != name) {
			continue
		}
		fault.remaining--
		if fault.remaining <= 0 {
			f.faults = append(f.faults[:i], f.faults[i+1:]...)
		}
		return &fs.PathError{Op: opName, Path: name, Err: fault.err}
	}
	return nil
}

type fakeFile struct {
	disk     *Fake
	name     string
	data     *fakeData
	canWrite bool
	isClosed bool
}

func (file *fakeFile) ReadAt(b []byte, off int64) (int, error) {
	f := file.disk
	f.mu.Lock()
	defer f.mu.Unlock()
	if file.isClosed {
		return 0, &fs.PathError{Op: "read", Path: file.name, Err: fs.ErrClosed}
	}
	if err := f.matchFault(file.name, OpRead, "read"); err != nil {
		return 0, err
	}
	if off >= int64(len(file.data.bytes)) {
		return 0, io.EOF
	}
	n := copy(b, file.data.bytes[off:])
	if n < len(b) {
		return n, io.EOF
	}
	return n, nil
}

func (file *fakeFile) WriteAt(b []byte, off int64) (int, error) {
	f := file.disk
	f.mu.Lock()
	defer f.mu.Unlock()
	if file.isClosed {
		return 0, &fs.PathError{Op: "write", Path: file.name, Err: fs.ErrClosed}
	}
	if !file.canWrite {
		return 0, &fs.PathError{Op: "write", Path: file.name, Err: syscall.EBADF}
	}
	if err := f.matchFault(file.name, OpWrite, "write"); err != nil {
		return 0, err
	}
	if end := off + int64(len(b)); end > int64(len(file.data.bytes)) {
		file.data.bytes = append(file.data.bytes, make([]byte, end-int64(len(file.data.bytes)))...)
	}
	return copy(file.data.bytes[off:], b), nil
}

func (file *fakeFile) Sync() error {
	f := file.disk
	f.mu.Lock()
	defer f.mu.Unlock()
	if file.isClosed {
		return &fs.PathError{Op: "sync", Path: file.name, Err: fs.ErrClosed}
	}
	return f.matchFault(file.name, OpSync, "sync")
}

func (file *fakeFile) Close() error {
	f := file.disk
	f.mu.Lock()
	defer f.mu.Unlock()
	if file.isClosed {
		return &fs.PathError{Op: "close", Path: file.name, Err: fs.ErrClosed}
	}
	file.isClosed = true
	return nil
}
