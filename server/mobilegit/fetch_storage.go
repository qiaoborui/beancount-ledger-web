package mobilegit

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/format/packfile"
	"github.com/go-git/go-git/v5/plumbing/storer"
	"github.com/go-git/go-git/v5/storage"
)

const maxFetchObjects = 100000
const maxCacheBytes = 512 << 20

// Receive into a bounded temporary pack, check declared sizes before inflating
// objects, then parse through a bounded lazy writer. Remote refs advance only
// after the pack has passed these checks. Credentials never enter this store.
type fetchStorage struct {
	storage.Storer
	ctx       context.Context
	root      string
	remaining int64
	objects   int
}

func newFetchStorage(ctx context.Context, base storage.Storer, root string) (*fetchStorage, error) {
	var size int64
	if err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		size += info.Size()
		if size > maxCacheBytes {
			return fail("limit_exceeded", "Git cache exceeds 512 MiB")
		}
		return nil
	}); err != nil {
		return nil, err
	}
	remaining := int64(maxCacheBytes) - size
	if remaining > maxTotalBytes {
		remaining = maxTotalBytes
	}
	return &fetchStorage{Storer: base, ctx: ctx, root: root, remaining: remaining}, nil
}

func (s *fetchStorage) IterReferences() (storer.ReferenceIter, error) {
	iterator, err := s.Storer.IterReferences()
	if err != nil {
		return nil, err
	}
	defer iterator.Close()
	var references []*plumbing.Reference
	if err := iterator.ForEach(func(reference *plumbing.Reference) error {
		if reference.Name().IsRemote() {
			references = append(references, reference)
		}
		return nil
	}); err != nil {
		return nil, err
	}
	return storer.NewReferenceSliceIter(references), nil
}

func (s *fetchStorage) PackfileWriter() (io.WriteCloser, error) {
	file, err := os.CreateTemp(s.root, "mobilegit-fetch-*.pack")
	if err != nil {
		return nil, err
	}
	return &fetchPackWriter{file: file, storage: s, remaining: maxTotalBytes}, nil
}

type fetchPackWriter struct {
	file      *os.File
	storage   *fetchStorage
	remaining int64
	failed    error
}

func (w *fetchPackWriter) Write(p []byte) (int, error) {
	if err := w.storage.ctx.Err(); err != nil {
		w.failed = err
		return 0, err
	}
	if int64(len(p)) > w.remaining {
		w.failed = fail("limit_exceeded", "Incoming Git pack exceeds 256 MiB")
		return 0, w.failed
	}
	n, err := w.file.Write(p)
	w.remaining -= int64(n)
	if err != nil {
		w.failed = err
	}
	return n, err
}
func (w *fetchPackWriter) Close() (err error) {
	defer func() { err = errors.Join(err, w.file.Close()); _ = os.Remove(w.file.Name()) }()
	if w.failed != nil {
		return w.failed
	}
	if err := w.storage.ctx.Err(); err != nil {
		return err
	}
	if _, err := w.file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	scanner := packfile.NewScanner(contextReader{w.storage.ctx, w.file})
	_, count, err := scanner.Header()
	if err != nil {
		return err
	}
	if count > maxFetchObjects {
		return fail("limit_exceeded", "Incoming Git pack exceeds 100000 objects")
	}
	var expanded int64
	for index := uint32(0); index < count; index++ {
		header, err := scanner.NextObjectHeader()
		if err != nil {
			return err
		}
		expanded += header.Length
		if header.Length < 0 || header.Length > maxFileBytes || expanded > maxTotalBytes {
			return fail("limit_exceeded", "Incoming Git objects exceed 64 MiB each or 256 MiB total")
		}
		bounded := &packPreflightWriter{ctx: w.storage.ctx, remaining: header.Length}
		actual, _, err := scanner.NextObject(bounded)
		if err != nil {
			return err
		}
		if actual != header.Length || bounded.remaining != 0 {
			return fail("invalid_request", "Git object length differs from its declared size")
		}
	}
	if _, err := w.file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	parser, err := packfile.NewParserWithStorage(packfile.NewScanner(w.file), w.storage)
	if err != nil {
		return err
	}
	_, err = parser.Parse()
	return err
}

// Scanner.NextObject inflates the entire zlib stream, independently of the
// object header. Reject excess bytes while streaming, before the parser can
// allocate a delta instruction buffer using attacker-controlled contents.
type packPreflightWriter struct {
	ctx       context.Context
	remaining int64
}

func (w *packPreflightWriter) Write(p []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	if int64(len(p)) > w.remaining {
		return 0, fail("limit_exceeded", "Inflated Git object exceeds its declared size")
	}
	w.remaining -= int64(len(p))
	return len(p), nil
}

func (s *fetchStorage) LazyWriter() (io.WriteCloser, func(plumbing.ObjectType, int64) error, error) {
	base, ok := s.Storer.(interface {
		LazyWriter() (io.WriteCloser, func(plumbing.ObjectType, int64) error, error)
	})
	if !ok {
		return nil, nil, fail("failed", "Git cache does not support bounded object writes")
	}
	bounded := &fetchObjectWriter{ctx: s.ctx}
	return bounded, func(kind plumbing.ObjectType, size int64) error {
		if err := s.ctx.Err(); err != nil {
			return err
		}
		s.objects++
		if size < 0 || size > maxFileBytes || size > s.remaining || s.objects > maxFetchObjects {
			return fail("limit_exceeded", "Expanded Git objects exceed the local cache budget")
		}
		s.remaining -= size
		bounded.remaining = size
		writer, header, err := base.LazyWriter()
		if err != nil {
			return err
		}
		bounded.writer = writer
		return header(kind, size)
	}, nil
}

type fetchObjectWriter struct {
	ctx       context.Context
	writer    io.WriteCloser
	remaining int64
}

func (w *fetchObjectWriter) Write(p []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	if int64(len(p)) > w.remaining {
		return 0, fail("limit_exceeded", "Git object exceeded its declared size")
	}
	if w.writer == nil {
		return 0, fail("failed", "Git object header is required before writing")
	}
	n, err := w.writer.Write(p)
	w.remaining -= int64(n)
	return n, err
}
func (w *fetchObjectWriter) Close() error {
	if w.writer == nil {
		return nil
	}
	return w.writer.Close()
}
