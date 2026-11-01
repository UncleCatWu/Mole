package main

import (
	"testing"

	"github.com/shirou/gopsutil/v4/disk"
)

func TestHardeningCoreIndependentEqualCapacityDisks(t *testing.T) {
	oldPartitions, oldUsage := diskPartitionsFunc, diskUsageFunc
	t.Cleanup(func() { diskPartitionsFunc, diskUsageFunc = oldPartitions, oldUsage })
	for _, fstype := range []string{"exfat", "apfs"} {
		diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
			return []disk.PartitionStat{{Device: "/dev/disk8s1", Mountpoint: "/Volumes/First", Fstype: fstype},
				{Device: "/dev/disk9s1", Mountpoint: "/Volumes/Second", Fstype: fstype}}, nil
		}
		diskUsageFunc = func(path string) (*disk.UsageStat, error) {
			return &disk.UsageStat{Path: path, Fstype: fstype, Total: 2 << 30, Used: 1 << 30, UsedPercent: 50}, nil
		}
		result, err := collectDisksFast()
		if err != nil || len(result) != 2 {
			t.Fatalf("independent %s disks disappeared: %+v err=%v", fstype, result, err)
		}
	}
	// A shared synthesized APFS device is real shared-pool evidence.
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{{Device: "/dev/disk8s1", Mountpoint: "/", Fstype: "apfs"},
			{Device: "/dev/disk8s2", Mountpoint: "/Volumes/Sibling", Fstype: "apfs"}}, nil
	}
	result, err := collectDisksFast()
	if err != nil || len(result) != 1 {
		t.Fatalf("shared APFS device was counted twice: %+v err=%v", result, err)
	}
}
