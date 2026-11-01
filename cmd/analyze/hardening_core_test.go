//go:build darwin

package main

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func hardeningModel(root string) model {
	var files, dirs, bytes int64
	current := &atomic.Value{}
	current.Store("")
	return model{path: root, cache: map[string]historyEntry{}, multiSelected: map[string]bool{},
		largeMultiSelected: map[string]bool{}, overviewSizeCache: map[string]int64{},
		overviewScanningSet: map[string]bool{}, filesScanned: &files, dirsScanned: &dirs,
		bytesScanned: &bytes, currentPath: current, width: 100, height: 30}
}

func TestHardeningCoreDeleteIsSingleFlight(t *testing.T) {
	m := hardeningModel(t.TempDir())
	m.entriesAll = []dirEntry{{Name: "first", Path: filepath.Join(m.path, "first"), Size: 1},
		{Name: "second", Path: filepath.Join(m.path, "second"), Size: 1}}
	m.entries = m.entriesAll
	updated, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyBackspace})
	m = updated.(model)
	updated, firstCmd := m.updateKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = updated.(model)
	if !m.deleting || firstCmd == nil {
		t.Fatal("positive control: first delete was not dispatched")
	}
	// Returned delete commands are deliberately never executed.
	for _, key := range []tea.KeyType{tea.KeyDown, tea.KeyBackspace, tea.KeyEnter, tea.KeyRight, tea.KeyEsc} {
		updated, cmd := m.updateKey(tea.KeyMsg{Type: key})
		m = updated.(model)
		if cmd != nil || m.selected != 0 || m.deleteConfirm {
			t.Fatalf("active delete accepted hidden navigation/confirmation: key=%v selected=%d confirm=%v", key, m.selected, m.deleteConfirm)
		}
	}
}

func TestHardeningCoreOldStartupCannotReplaceRefresh(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	resetOverviewSnapshotForTest()
	root := t.TempDir()
	oldFile := filepath.Join(root, "old-row.bin")
	if err := os.WriteFile(oldFile, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	m := hardeningModel(root)
	oldStart := m.scanFreshCmd(root)().(liveScanStartMsg)
	defer cancelAndDrainLiveScan(oldStart)
	if err := os.Remove(oldFile); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "new-row.bin"), []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	updated, refresh := m.updateKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'r'}})
	m = updated.(model)
	batch := refresh().(tea.BatchMsg)
	newStart := batch[0]().(liveScanStartMsg)
	defer cancelAndDrainLiveScan(newStart)
	updated, _ = m.Update(newStart)
	m = updated.(model)
	if m.liveScanID != newStart.id || len(m.entries) != 1 || m.entries[0].Name != "new-row.bin" {
		t.Fatal("positive control: newer request was not accepted")
	}
	updated, _ = m.Update(oldStart)
	m = updated.(model)
	if m.liveScanID != newStart.id || m.entries[0].Name != "new-row.bin" {
		t.Fatal("older same-path startup replaced the refresh")
	}
}

func TestHardeningCoreNestedDeleteInvalidatesChildCache(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	resetOverviewSnapshotForTest()
	root := t.TempDir()
	sub := filepath.Join(root, "sub")
	file := filepath.Join(sub, "large.bin")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, make([]byte, 11<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	size := getActualFileSize(file, info)
	old := scanResult{Entries: []dirEntry{{Name: "large.bin", Path: file, Size: size}},
		LargeFiles: []fileEntry{{Name: "large.bin", Path: file, Size: size}}, TotalSize: size, TotalFiles: 1}
	if err := saveCacheToDiskWithOptions(newScanPublication(context.Background(), nil), sub, old, true); err != nil {
		t.Fatal(err)
	}
	if cached, err := loadCacheFromDisk(sub); err != nil || cached.TotalSize != size {
		t.Fatalf("positive control: child cache not seeded: %v", err)
	}
	if err := os.Remove(file); err != nil { // Only the private fixture is removed.
		t.Fatal(err)
	}
	m := hardeningModel(root)
	m.deleting = true
	m.showLargeFiles = true
	m.largeFilesAll, m.largeFiles = old.LargeFiles, old.LargeFiles
	m.entriesAll = []dirEntry{{Name: "sub", Path: sub, Size: size, IsDir: true}}
	m.entries = m.entriesAll
	updated, cmd := m.Update(deleteProgressMsg{done: true, path: file, count: 1})
	m = updated.(model)
	if cmd == nil || !m.scanning {
		t.Fatal("post-delete refresh was not scheduled")
	}
	if _, err := loadCacheFromDisk(sub); !os.IsNotExist(err) {
		t.Fatalf("deleted file's parent cache survived: %v", err)
	}
	fresh := runScanResultCmd(t, cmd)
	if fresh.result.TotalSize != 0 || len(fresh.result.LargeFiles) != 0 {
		t.Fatalf("automatic refresh resurrected deleted file: %+v", fresh.result)
	}
}
