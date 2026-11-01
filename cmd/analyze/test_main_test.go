//go:build darwin

package main

import (
	"context"
	"errors"
	"os"
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
	os.Exit(m.Run())
}
