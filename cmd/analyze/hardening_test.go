//go:build darwin

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func TestHardeningDeleteReceiptBindsOperationAndParent(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	resetOverviewSnapshotForTest()
	origin, current := t.TempDir(), t.TempDir()
	removed := filepath.Join(origin, "removed.bin")
	m := hardeningModel(current)
	m.deleteOperationID, m.deleteParentPath, m.deleting = 8, origin, true
	m.cache[origin], m.cache[current] = historyEntry{}, historyEntry{}
	m.entriesAll = []dirEntry{{Name: "unrelated", Path: filepath.Join(current, "unrelated"), Size: 5}}
	m.entries, m.totalSize = m.entriesAll, 5
	m.liveScanID = 20
	for _, receipt := range []deleteProgressMsg{
		{done: true, operationID: 7, parentPath: origin, path: removed},
		{done: true, operationID: 8, parentPath: current, path: removed},
	} {
		updated, cmd := m.Update(receipt)
		m = updated.(model)
		if !m.deleting || cmd != nil {
			t.Fatal("unmatched deletion receipt changed the active operation")
		}
	}
	updated, cmd := m.Update(deleteProgressMsg{done: true, operationID: 8, parentPath: origin, path: removed, count: 1})
	m = updated.(model)
	if m.deleting || cmd != nil || m.totalSize != 5 || m.liveScanID != 20 || m.cache[current].NeedsRefresh {
		t.Fatal("matching origin receipt altered the unrelated current view")
	}
	if !m.cache[origin].NeedsRefresh {
		t.Fatal("positive control: original parent was not marked stale")
	}
}

func TestHardeningQuitCancelsBeforeAnyDeleteSink(t *testing.T) {
	m := hardeningModel(t.TempDir())
	target := filepath.Join(m.path, "eligible.bin")
	if err := os.WriteFile(target, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	m.entriesAll = []dirEntry{{Name: "eligible.bin", Path: target, Size: 4}}
	m.entries = m.entriesAll
	updated, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyBackspace})
	m = updated.(model)
	updated, queued := m.updateKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = updated.(model)
	if queued == nil || !m.deleting {
		t.Fatal("positive control: delete was not queued")
	}
	updated, quit := m.updateKey(tea.KeyMsg{Type: tea.KeyCtrlC})
	m = updated.(model)
	if quit != nil || !m.quitAfterDelete {
		t.Fatal("quit must wait for the canceled operation's receipt")
	}
	// The canceled context returns before Lstat or any external mutation seam.
	receipt := queued().(tea.BatchMsg)[0]().(deleteProgressMsg)
	if !errors.Is(receipt.err, context.Canceled) || receipt.count != 0 {
		t.Fatalf("queued delete was not canceled: %+v", receipt)
	}
	updated, quit = m.Update(receipt)
	if updated.(model).deleting || quit == nil {
		t.Fatal("matching cancellation receipt did not finish and quit")
	}
	if _, ok := quit().(tea.QuitMsg); !ok {
		t.Fatal("expected a final quit command")
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "keep" {
		t.Fatalf("canceled fixture changed: %q %v", data, err)
	}
}

func TestHardeningTerminalTrashOutcomeStopsFallbackAndBatch(t *testing.T) {
	for _, mode := range []string{"canceled", "ambiguous"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			first, second := filepath.Join(root, "first.bin"), filepath.Join(root, "second.bin")
			for _, path := range []string{first, second} {
				if err := os.WriteFile(path, []byte("eligible"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			oldProbe, oldBinary, oldFS, oldFinder := trashBinaryProbe, trashBinaryRunner, trashFilesystemRunner, trashFinderRunner
			t.Cleanup(func() {
				trashBinaryProbe, trashBinaryRunner, trashFilesystemRunner, trashFinderRunner = oldProbe, oldBinary, oldFS, oldFinder
			})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			binaryCalls, fallbackCalls := 0, 0
			trashBinaryProbe = func() error { return nil }
			trashBinaryRunner = func(context.Context, string) ([]byte, error) {
				binaryCalls++
				if mode == "canceled" {
					cancel()
				}
				return nil, errors.New("unknown command completion")
			}
			trashFilesystemRunner = func(string, ...context.Context) error { fallbackCalls++; return nil }
			trashFinderRunner = func(context.Context, string) ([]byte, error) { fallbackCalls++; return nil, nil }
			receipt := deleteMultiplePathsCmd([]string{first, second}, nil, nil, deleteRequest{ctx: ctx})().(deleteProgressMsg)
			if binaryCalls != 1 || fallbackCalls != 0 || receipt.count != 0 || !isTerminalDeleteError(receipt.err) {
				t.Fatalf("terminal outcome did not stop later sinks: binary=%d fallback=%d receipt=%+v", binaryCalls, fallbackCalls, receipt)
			}
			// Second target is otherwise eligible; a positive first call proves the
			// assertion did not pass because every candidate was filtered out.
			if data, err := os.ReadFile(second); err != nil || string(data) != "eligible" {
				t.Fatal("second eligible target changed")
			}
		})
	}
}

func TestHardeningUnavailableBinaryUsesKnownFilesystemFallback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "target.bin")
	if err := os.WriteFile(path, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	oldProbe, oldFS := trashBinaryProbe, trashFilesystemRunner
	t.Cleanup(func() { trashBinaryProbe, trashFilesystemRunner = oldProbe, oldFS })
	trashBinaryProbe = func() error { return os.ErrNotExist }
	calls := 0
	trashFilesystemRunner = func(got string, contexts ...context.Context) error {
		calls++
		if got != path || deleteContext(contexts).Err() != nil {
			t.Fatal("fallback did not receive the bound target and context")
		}
		return nil // Positive mock; no file is moved.
	}
	if err := moveToTrash(path); err != nil || calls != 1 {
		t.Fatalf("safe missing-binary fallback failed: calls=%d err=%v", calls, err)
	}
}

func TestHardeningDefaultExternalDeleteSeamsAreBlocked(t *testing.T) {
	for _, runner := range []func(context.Context, string) ([]byte, error){trashBinaryRunner, trashFinderRunner} {
		if _, err := runner(context.Background(), "test"); err == nil || !strings.Contains(err.Error(), "disabled in tests") {
			t.Fatal("test process did not block its real external deletion seam")
		}
	}
}

func TestHardeningCacheResultRequiresCurrentRequest(t *testing.T) {
	m := hardeningModel(t.TempDir())
	m.liveScanID, m.scanning, m.totalSize = 2, true, 10
	updated, cmd := m.Update(scanResultMsg{id: 1, path: m.path, result: scanResult{TotalSize: 999}})
	m = updated.(model)
	if cmd != nil || !m.scanning || m.totalSize != 10 {
		t.Fatal("older cache return prematurely completed the current scan")
	}
	updated, _ = m.Update(scanResultMsg{id: 2, path: m.path, result: scanResult{TotalSize: 20}})
	if got := updated.(model); got.scanning || got.totalSize != 20 {
		t.Fatal("positive control: matching cache return was not applied")
	}
}

func TestHardeningQueuedScanCanceledBeforeStartup(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root := t.TempDir()
	m := newModel(root, false)
	queued := m.scanFreshCmd(root)
	updated, refresh := m.updateKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'r'}})
	m = updated.(model)
	old := queued().(liveScanStartMsg)
	if !errors.Is(old.err, context.Canceled) || old.events != nil {
		t.Fatal("abandoned queued request started background workers")
	}
	fresh := refresh().(tea.BatchMsg)[0]().(liveScanStartMsg)
	defer cancelAndDrainLiveScan(fresh)
	if fresh.err != nil || fresh.events == nil {
		t.Fatal("positive control: replacement request could not start")
	}
	m.cancelLiveScan()
}

func TestHardeningCanceledOverviewProbeCannotPublishSnapshot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	downloads := filepath.Join(home, "Downloads")
	if err := os.Mkdir(downloads, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(downloads, "old.bin")
	if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, time.Now().AddDate(0, 0, -120), time.Now().AddDate(0, 0, -120)); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	stopped := scanOverviewPathCmd(downloads, 0, newScanPublication(ctx, nil))().(overviewSizeMsg)
	if !errors.Is(stopped.Err, context.Canceled) {
		t.Fatal("canceled overview probe was treated as a measurement")
	}
	if _, err := loadStoredOverviewSize(downloads); err == nil {
		t.Fatal("canceled overview probe populated persistent derived data")
	}
	live := scanOverviewPathCmd(downloads, 0, newScanPublication(context.Background(), nil))().(overviewSizeMsg)
	if live.Err != nil || live.Size != 3 {
		t.Fatal("positive control: matching live probe did not measure the fixture")
	}
}

func TestHardeningOverviewEpochAndRemainingSlots(t *testing.T) {
	m := hardeningModel("/")
	m.isOverview = true
	for i := range maxConcurrentOverview + 5 {
		path := filepath.Join("/fixture", strings.Repeat("x", i+1))
		m.entries = append(m.entries, dirEntry{Path: path, Size: -1})
		if i < maxConcurrentOverview-1 {
			m.overviewScanningSet[path] = newScanRequestPublication(m.lifetimeContext())
		}
	}
	defer m.cancelOverviewScans(nil)
	if cmd := m.scheduleOverviewScans(); cmd == nil || len(m.overviewScanningSet) != maxConcurrentOverview {
		t.Fatal("one remaining slot did not schedule exactly one probe")
	}
	first := m.entries[0].Path
	old := m.overviewScanningSet[first]
	old.cancel()
	current := newScanRequestPublication(m.lifetimeContext())
	m.overviewScanningSet[first] = current
	updated, _ := m.Update(overviewSizeMsg{publication: old, Path: first, Size: 999})
	m = updated.(model)
	if m.entries[0].Size != -1 || len(m.overviewScanningSet) != maxConcurrentOverview || m.overviewScanningSet[first] != current {
		t.Fatal("old overview result changed the measurement or exceeded the probe budget")
	}
	updated, _ = m.Update(overviewSizeMsg{publication: current, Path: first, Size: 50})
	m = updated.(model)
	if m.entries[0].Size != 50 || len(m.overviewScanningSet) != maxConcurrentOverview {
		t.Fatal("matching overview result was not applied with bounded refill")
	}
}

func TestHardeningOverviewTotalUsesMeasuredCoverage(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	library, downloads := filepath.Join(home, "Library"), filepath.Join(home, "Downloads")
	derived := filepath.Join(library, "Developer", "Xcode", "DerivedData")
	tests := []struct {
		name    string
		entries []dirEntry
		want    int64
	}{
		{"disjoint Home and Library plus overlapping insights", []dirEntry{{Path: home, Size: 100}, {Path: library, Size: 50}, {Path: derived, Size: 30}, {Path: downloads, Size: 20}}, 150},
		{"unknown parent retains measured child", []dirEntry{{Path: library, Size: -1}, {Path: derived, Size: 30}}, 30},
		{"failed parent retains measured child", []dirEntry{{Path: library, Size: 0}, {Path: derived, Size: 30}}, 30},
		{"age scoped Downloads cannot cover recent descendants", []dirEntry{{Path: downloads, Size: 20}, {Path: filepath.Join(downloads, "recent"), Size: 11}}, 31},
		{"excluded cloud tree is not covered", []dirEntry{{Path: library, Size: 50}, {Path: filepath.Join(library, "Mobile Documents", "data"), Size: 12}}, 62},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := sumKnownEntrySizes(test.entries); got != test.want {
				t.Fatalf("overview total=%d, want %d", got, test.want)
			}
		})
	}
}

func TestHardeningOverviewCacheNeverFallsBackToDirectoryScope(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	downloads := filepath.Join(home, "Downloads")
	if err := os.Mkdir(downloads, 0o700); err != nil {
		t.Fatal(err)
	}
	old := filepath.Join(downloads, "old.bin")
	for path, contents := range map[string]string{old: "old", filepath.Join(downloads, "recent.bin"): "new payload"} {
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chtimes(old, time.Now().AddDate(0, 0, -120), time.Now().AddDate(0, 0, -120)); err != nil {
		t.Fatal(err)
	}
	if err := saveCacheToDisk(downloads, scanResult{TotalSize: 999}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadOverviewCachedMeasurement(downloads); err == nil {
		t.Fatal("full Downloads cache was accepted as a 90-day overview measurement")
	}
	size, err := measureInsightSize(context.Background(), downloads)
	if err != nil || size != 3 {
		t.Fatalf("old Downloads measurement=%d err=%v", size, err)
	}
	if cached, _, err := loadOverviewCachedMeasurement(downloads); err != nil || cached != 3 {
		t.Fatal("positive control: scoped overview measurement was not cached")
	}
}

func TestHardeningCompletedScanSaveIsDetachedAndKeepsOverviewScope(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	if err := storeOverviewSize(home, 10); err != nil {
		t.Fatal(err)
	}
	m := hardeningModel(home)
	a, b := filepath.Join(home, "a"), filepath.Join(home, "b")
	result := scanResult{Entries: []dirEntry{{Path: a, Size: 10}, {Path: b, Size: 20}},
		LargeFiles: []fileEntry{{Path: a, Size: 10}, {Path: b, Size: 20}}, TotalSize: 30}
	oldSave := saveCompletedScan
	t.Cleanup(func() { saveCompletedScan = oldSave })
	gate := make(chan struct{})
	saved := make(chan scanResult, 1)
	saveCompletedScan = func(_ *scanPublication, _ string, scan scanResult, _ bool) error {
		<-gate
		saved <- cloneScanResult(scan)
		return nil
	}
	m.finishLiveScan(result)
	m.removePathFromView(a)
	close(gate)
	select {
	case snapshot := <-saved:
		if !slices.EqualFunc(snapshot.Entries, result.Entries, func(a, b dirEntry) bool { return a.Path == b.Path }) ||
			len(snapshot.LargeFiles) != 2 || snapshot.LargeFiles[0].Path != a {
			t.Fatal("model mutation changed the asynchronous save's backing slices")
		}
	case <-time.After(time.Second):
		t.Fatal("positive control: asynchronous save did not run")
	}
	if size, err := loadStoredOverviewSize(home); err != nil || size != 10 {
		t.Fatal("full Home scan overwrote the Library-excluding overview scope")
	}
	m.cancelLiveScan()
}
