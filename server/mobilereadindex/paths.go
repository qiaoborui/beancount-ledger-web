//go:build cgo

package mobilereadindex

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"

	"github.com/borui/beancount-ledger-web/server/internal/readindex"
)

const maxPathBytes = 4096

func validPath(path string) bool {
	if path == "" || len(path) > maxPathBytes || !utf8.ValidString(path) || strings.ContainsRune(path, 0) {
		return false
	}
	for _, part := range strings.Split(path, string(filepath.Separator)) {
		if part == ".." {
			return false
		}
	}
	return true
}

func owned(info os.FileInfo, mode os.FileMode) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && st.Uid == uint32(os.Geteuid()) && info.Mode().Perm() == mode && info.Mode()&(os.ModeSymlink|os.ModeSetuid|os.ModeSetgid|os.ModeSticky) == 0
}

// Above the private root we require non-symlink, non-writable trusted ancestors
// (root-owned sticky system temporary directories are safe for owned children).
func ancestors(path string) bool {
	for p := filepath.Dir(path); ; p = filepath.Dir(p) {
		info, err := os.Lstat(p)
		if err != nil || !info.IsDir() {
			return false
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok || (st.Uid != 0 && st.Uid != uint32(os.Geteuid())) {
			return false
		}
		if info.Mode().Perm()&0022 != 0 && !(st.Uid == 0 && info.Mode()&os.ModeSticky != 0) {
			return false
		}
		if p == filepath.Dir(p) {
			return true
		}
	}
}

func pinRoot(root string) (string, os.FileInfo) {
	if !validPath(root) || !filepath.IsAbs(root) {
		return "", nil
	}
	root = filepath.Clean(root)
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || !owned(info, 0700) || !ancestors(root) {
		return "", nil
	}
	return root, info
}

func privateFile(info os.FileInfo) bool {
	st, ok := info.Sys().(*syscall.Stat_t)
	return info.Mode().IsRegular() && owned(info, 0600) && ok && st.Nlink == 1
}

func (b *Bridge) checkedPath(path string, destination bool) (string, error) {
	bad := readindex.ErrInvalidRequest
	if !validPath(path) {
		return "", bad
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(b.root, path)
	}
	path = filepath.Clean(path)
	if len(path) > maxPathBytes {
		return "", bad
	}
	rel, err := filepath.Rel(b.root, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", bad
	}
	root, identity := pinRoot(b.root)
	if root == "" || !os.SameFile(identity, b.identity) {
		return "", readindex.ErrUnavailable
	}
	parts := strings.Split(rel, string(filepath.Separator))
	current := root
	for i, part := range parts {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		last := i == len(parts)-1
		if last && destination && os.IsNotExist(err) {
			return path, nil
		}
		if err != nil {
			return "", readindex.ErrUnavailable
		}
		if !last {
			if !info.IsDir() || !owned(info, 0700) {
				return "", readindex.ErrUnavailable
			}
		} else {
			if !privateFile(info) {
				return "", readindex.ErrUnavailable
			}
			if destination {
				return "", readindex.ErrExists
			}
		}
	}
	return path, nil
}

func openStream(path string) (*os.File, error) {
	before, err := os.Lstat(path)
	if err != nil || !privateFile(before) {
		return nil, readindex.ErrUnavailable
	}
	// NONBLOCK prevents a substituted FIFO from hanging before the fstat check.
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, readindex.ErrUnavailable
	}
	f := os.NewFile(uintptr(fd), path)
	after, err := f.Stat()
	if err != nil || !privateFile(after) || !os.SameFile(before, after) {
		_ = f.Close()
		return nil, readindex.ErrUnavailable
	}
	return f, nil
}
