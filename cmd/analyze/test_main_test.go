//go:build darwin

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestMain(m *testing.M) {
	// Default deny the external mutation seams. Individual tests can replace
	// them with a positive, private-fixture mock; no suite can reach real Trash.
	trashBinaryRunner = func(context.Context, string) ([]byte, error) {
		return nil, errors.New("real Trash binary disabled in tests")
	}
	trashFinderRunner = func(context.Context, string) ([]byte, error) {
		return nil, errors.New("real Finder deletion disabled in tests")
	}
	// The upstream audit tests also need a private log default for any case
	// that does not replace HOME. This complements the external-sink denial.
	scratch, err := os.MkdirTemp("", "mole-analyze-logs-")
	if err != nil {
		panic(err)
	}
	os.Setenv("MO_NO_OPLOG", "1")
	os.Setenv("MOLE_DELETE_LOG", filepath.Join(scratch, "deletions.log"))
	code := m.Run()
	os.RemoveAll(scratch)
	os.Exit(code)
}
