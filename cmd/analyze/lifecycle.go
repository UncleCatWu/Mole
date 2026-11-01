//go:build darwin

package main

import (
	"context"
	"sync"

	tea "github.com/charmbracelet/bubbletea"
)

// Shared by every model generation. Register active mutation under the same
// mutex as shutdown, so a queued command cannot begin after stop starts.
type analyzerLifecycle struct {
	ctx      context.Context
	cancel   context.CancelFunc
	mu       sync.Mutex
	stopping bool
	active   sync.WaitGroup
}

func newAnalyzerLifecycle() *analyzerLifecycle {
	ctx, cancel := context.WithCancel(context.Background())
	l := &analyzerLifecycle{cancel: cancel}
	l.ctx = context.WithValue(ctx, analyzerLifecycleKey{}, l)
	return l
}
func (l *analyzerLifecycle) stop() {
	if l == nil {
		return
	}
	l.mu.Lock()
	l.stopping = true
	l.cancel()
	l.mu.Unlock()
	l.active.Wait()
}
func (m model) lifetimeContext() context.Context {
	if m.lifecycle != nil {
		return m.lifecycle.ctx
	}
	return context.Background()
}

type analyzerLifecycleKey struct{}
type overviewPublicationKey struct{}

func (l *analyzerLifecycle) begin() (func(), bool) {
	if l == nil {
		return func() {}, true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.stopping || l.ctx.Err() != nil {
		return nil, false
	}
	l.active.Add(1)
	return l.active.Done, true
}
func startAnalyzerWork(ctx context.Context, work func()) bool {
	l, _ := ctx.Value(analyzerLifecycleKey{}).(*analyzerLifecycle)
	done, admitted := l.begin()
	if !admitted {
		return false
	}
	if ctx.Err() != nil {
		done()
		return false
	}
	go func() { defer done(); work() }()
	return true
}
func (m model) trackWork(cmd tea.Cmd) tea.Cmd {
	if cmd == nil {
		return nil
	}
	return func() tea.Msg {
		done, admitted := m.lifecycle.begin()
		if !admitted {
			return nil
		}
		defer done()
		return cmd()
	}
}
func (m model) trackDelete(cmd tea.Cmd) tea.Cmd { return m.trackWork(cmd) }

func newScanRequestPublication(parent context.Context) *scanPublication {
	ctx, cancel := context.WithCancel(parent)
	publication := newScanPublication(ctx, cancel)
	publication.ctx = context.WithValue(ctx, overviewPublicationKey{}, publication)
	return publication
}
func overviewPublicationFromContext(ctx context.Context) *scanPublication {
	if publication, ok := ctx.Value(overviewPublicationKey{}).(*scanPublication); ok {
		return publication
	}
	return newScanPublication(ctx, nil)
}
func (m model) stopForExit() {
	if m.lifecycle != nil {
		m.lifecycle.cancel()
	}
	if m.deleteCancel != nil {
		m.deleteCancel()
	}
	m.cancelLiveScan()
	m.cancelOverviewScans(nil)
	m.cancelBackgroundCacheWrites(nil)
	m.lifecycle.stop()
}

// Bubble Tea consumes QuitMsg and InterruptMsg before invoking Update.
func analyzerExitFilter(current tea.Model, msg tea.Msg) tea.Msg {
	switch msg.(type) {
	case tea.QuitMsg, tea.InterruptMsg:
		if final, ok := current.(interface{ stopForExit() }); ok {
			final.stopForExit()
		}
	}
	return msg
}
