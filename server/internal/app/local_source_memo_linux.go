package app

import (
	"os"
	"syscall"
)

func localSourceStatIdentity(info os.FileInfo) (device, inode uint64, changedNsec int64, ok bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, 0, false
	}
	return uint64(stat.Dev), stat.Ino, stat.Ctim.Nano(), true
}
