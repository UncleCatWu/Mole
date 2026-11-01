package main

import (
	"context"
	"errors"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/load"
)

func TestHardeningBatteryProbeHasDeadlineAndReleasesCollector(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("pmset is macOS-only")
	}
	oldRunner, oldExists := runCmd, commandExists
	t.Cleanup(func() { runCmd, commandExists = oldRunner, oldExists })
	commandExists = func(name string) bool { return name == "pmset" }
	called, independent := false, false
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		if name != "pmset" {
			t.Errorf("unexpected device command: %s", name)
		}
		called = true
		if _, ok := ctx.Deadline(); !ok {
			return "", errors.New("pmset context is not bounded")
		}
		<-ctx.Done()
		return "", ctx.Err()
	}
	start := time.Now()
	err := collectConcurrently(func() error { _, err := collectBatteries(); return err },
		func() error { independent = true; return nil })
	if !called || !independent || !errors.Is(err, context.DeadlineExceeded) || time.Since(start) > batteryCommandTimeout+time.Second {
		t.Fatalf("bounded battery collection failed: called=%v other=%v elapsed=%v err=%v", called, independent, time.Since(start), err)
	}
}

func TestHardeningDefaultDeviceCommandsAreBlocked(t *testing.T) {
	for _, name := range []string{"pmset", "osascript", "diskutil", "ioreg", "powermetrics", "system_profiler"} {
		if _, err := runCmd(context.Background(), name); err == nil || !strings.Contains(err.Error(), "disabled in tests") {
			t.Fatalf("real command %s is not blocked by the test process", name)
		}
	}
	if counters, err := diskIOCountersFunc(); err != nil || len(counters) != 1 || counters["fixture"].Name != "fixture" {
		t.Fatal("native device counters are not isolated to the positive fixture")
	}
}

func TestHardeningFastAndFullCPUUseSameParkedCoreAccounting(t *testing.T) {
	oldTimes, oldClock, oldSampler, oldCounts, oldLoad, oldRunner := cpuTimesFunc, cpuClock, cpuUtilSampler, cpuCountsFunc, cpuLoadFunc, runCmd
	oldP, oldE, oldTopology := cachedP, cachedE, lastTopologyAt
	t.Cleanup(func() {
		cpuTimesFunc, cpuClock, cpuUtilSampler, cpuCountsFunc, cpuLoadFunc, runCmd = oldTimes, oldClock, oldSampler, oldCounts, oldLoad, oldRunner
		cachedP, cachedE, lastTopologyAt = oldP, oldE, oldTopology
	})
	cpuCountsFunc = func(bool) (int, error) { return 1, nil }
	cpuLoadFunc = func() (*load.AvgStat, error) { return &load.AvgStat{Load1: 1, Load5: 1, Load15: 1}, nil }
	runCmd = func(context.Context, string, ...string) (string, error) { return "1\n1\n", nil }
	cachedP, cachedE, lastTopologyAt = 0, 0, time.Time{}
	before := []cpu.TimesStat{{User: 10, System: 5, Idle: 100}}
	after := []cpu.TimesStat{{User: 10.01, System: 5.01, Idle: 100}}
	start := time.Now()
	timesCalls := 0
	cpuUtilSampler = &cpuUsageSampler{previous: before, at: start}
	cpuTimesFunc = func(bool) ([]cpu.TimesStat, error) { timesCalls++; return after, nil }
	cpuClock = func() time.Time { return start.Add(100 * time.Millisecond) }
	fast, err := collectCPUFast()
	if err != nil || !almostEqual(fast.Usage, 20) || fast.PerCoreEstimated {
		t.Fatalf("fast parked core reading: %+v err=%v", fast, err)
	}
	step := 0
	cpuTimesFunc = func(bool) ([]cpu.TimesStat, error) {
		timesCalls++
		step++
		if step == 1 {
			return before, nil
		}
		return after, nil
	}
	clockStep := 0
	cpuClock = func() time.Time {
		clockStep++
		if clockStep == 1 {
			return start
		}
		return start.Add(100 * time.Millisecond)
	}
	full, err := collectCPU()
	if err != nil || !almostEqual(full.Usage, fast.Usage) || !almostEqual(full.PerCore[0], fast.PerCore[0]) || timesCalls != 3 {
		t.Fatalf("cadences differ: fast=%+v full=%+v calls=%d err=%v", fast, full, timesCalls, err)
	}
}
