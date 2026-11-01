//go:build darwin

package main

import (
	"testing"

	"golang.org/x/sys/unix"
)

func TestOverviewEntriesForMounts(t *testing.T) {
	mount := func(path, device string, flags uint32) unix.Statfs_t {
		var entry unix.Statfs_t
		copy(entry.Mntonname[:], path)
		copy(entry.Mntfromname[:], device)
		entry.Flags = flags
		return entry
	}
	mounts := []unix.Statfs_t{
		mount("/", "/dev/disk3s1s1", unix.MNT_LOCAL),
		mount("/System/Volumes/Data", "/dev/disk3s5", unix.MNT_LOCAL),
		mount("/Volumes/General", "/dev/disk3s7", unix.MNT_LOCAL),
		mount("/Volumes/外接 SSD", "/dev/disk4s1", unix.MNT_LOCAL),
		mount("/Volumes/General", "/dev/disk3s7", unix.MNT_LOCAL),
		mount("/Volumes/Installer", "/dev/disk5s1", unix.MNT_LOCAL|unix.MNT_RDONLY),
		mount("/Volumes/Server", "//server/share", 0),
		mount("/Volumes/Hidden", "/dev/disk3s8", unix.MNT_LOCAL|unix.MNT_DONTBROWSE),
		mount("/Volumes/Disk/nested", "/dev/disk6s1", unix.MNT_LOCAL),
		mount("/Volumes/../escape", "/dev/disk6s2", unix.MNT_LOCAL),
	}
	entries := overviewEntriesForMounts(mounts)
	if len(entries) != 2 {
		t.Fatalf("got %v, want two local writable volume rows", entries)
	}
	for i, want := range []string{"General", "外接 SSD"} {
		entry := entries[i]
		if entry.Name != want || entry.Path != "/Volumes/"+want || !entry.IsDir || entry.Size != -1 {
			t.Errorf("row %d = %+v, want pending directory %q", i, entry, want)
		}
	}
	if entries := overviewEntriesForMounts(nil); len(entries) != 0 {
		t.Fatalf("empty mount table produced %v", entries)
	}
}
