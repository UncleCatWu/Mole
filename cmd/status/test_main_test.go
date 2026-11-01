package main

import (
	"context"
	"fmt"
	"os"
	"testing"

	"github.com/shirou/gopsutil/v4/disk"
)

func TestMain(m *testing.M) {
	// Native disk.IOCounters uses IOKit on macOS and does not pass through
	// runCmd. Keep it on a fixture as well as blocking device subprocesses.
	diskIOCountersFunc = func(...string) (map[string]disk.IOCountersStat, error) {
		return map[string]disk.IOCountersStat{"fixture": {Name: "fixture"}}, nil
	}
	ordinaryRunner := runCmd
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		switch name {
		case "pmset", "osascript", "diskutil", "system_profiler", "ioreg", "powermetrics", "bluetoothctl", "nvidia-smi":
			return "", fmt.Errorf("real device command %s disabled in tests", name)
		default:
			return ordinaryRunner(ctx, name, args...)
		}
	}
	os.Exit(m.Run())
}
