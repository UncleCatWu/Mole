//go:build darwin

package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// useFixtureTrash supplies a positive mover without contacting Finder or the
// account's real Trash. Every selected source is created by these tests.
func useFixtureTrash(t *testing.T) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	trash := filepath.Join(home, ".Trash")
	if err := os.Mkdir(trash, 0700); err != nil {
		t.Fatal(err)
	}
	oldProbe, oldRunner := trashBinaryProbe, trashBinaryRunner
	t.Cleanup(func() { trashBinaryProbe, trashBinaryRunner = oldProbe, oldRunner })
	trashBinaryProbe = func() error { return nil }
	calls := 0
	trashBinaryRunner = func(ctx context.Context, path string) ([]byte, error) {
		calls++
		if _, ok := ctx.Deadline(); !ok {
			t.Fatal("fixture Trash command is not bounded")
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return nil, os.Rename(path, filepath.Join(trash, filepath.Base(path)))
	}
	t.Cleanup(func() {
		if calls == 0 {
			t.Error("positive control: fixture Trash mover was never called")
		}
	})
}

// useDuStub points the size probe at a stub du for the rest of the test.
func useDuStub(t *testing.T, stub string) {
	t.Helper()
	previous := duBinary
	duBinary = stub
	t.Cleanup(func() { duBinary = previous })
}
