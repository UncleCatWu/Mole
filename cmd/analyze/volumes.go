//go:build darwin

package main

import (
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// Read the cached mount table, without probing or waking mounted filesystems.
// The existing overview workers size eligible volumes after the first paint.
func mountedVolumeOverviewEntries() []dirEntry {
	n, err := unix.Getfsstat(nil, unix.MNT_NOWAIT)
	if err != nil || n == 0 {
		return nil
	}
	mounts := make([]unix.Statfs_t, n+8)
	n, err = unix.Getfsstat(mounts, unix.MNT_NOWAIT)
	if err != nil {
		return nil
	}
	return overviewEntriesForMounts(mounts[:min(n, len(mounts))])
}

func overviewEntriesForMounts(mounts []unix.Statfs_t) []dirEntry {
	var entries []dirEntry
	seen := make(map[string]bool)
	for _, mount := range mounts {
		path := unix.ByteSliceToString(mount.Mntonname[:])
		device := unix.ByteSliceToString(mount.Mntfromname[:])
		// Local writable volumes only. Installer images are normally read-only;
		// network, hidden system and snapshot mounts do not belong in overview.
		if mount.Flags&unix.MNT_LOCAL == 0 || mount.Flags&(unix.MNT_RDONLY|unix.MNT_DONTBROWSE) != 0 ||
			!strings.HasPrefix(device, "/dev/disk") || filepath.Dir(path) != "/Volumes" ||
			filepath.Clean(path) != path || seen[path] {
			continue
		}
		seen[path] = true
		entries = append(entries, dirEntry{Name: filepath.Base(path), Path: path, IsDir: true, Size: -1})
	}
	return entries
}
