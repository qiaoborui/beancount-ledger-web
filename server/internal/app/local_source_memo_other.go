//go:build !darwin && !linux

package app

import "os"

// Without a change time the memo cannot tell an in-place edit apart, so
// these platforms always hash the file.
func localSourceStatIdentity(os.FileInfo) (device, inode uint64, changedNsec int64, ok bool) {
	return 0, 0, 0, false
}
